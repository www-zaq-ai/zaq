defmodule Zaq.UserPortal.Onboarding do
  @moduledoc """
  Owns the bootstrap onboarding flow: registration write, portal consent, and
  provisioning.

  This is the UserPortal boundary's orchestrator. Registration (email + password)
  is delegated to `Zaq.Accounts.complete_registration/2`; consent persistence and
  provisioning live here so success/failure of provisioning can drive the recorded
  consent value.

  In standard onboarding, registration is committed **before** provisioning
  contacts the Portal, so a provisioning failure does not block account creation.
  Existing-account connections exchange a one-time link first and only commit
  registration if local provisioning succeeds and the installation job is queued.

  On acceptance, provisioning runs synchronously after the account is written. If
  it fails, consent is recorded as `"declined"`, the keyless ZAQ Router credential
  is scaffolded so the provider stays listed, and `{:error, {:provisioning_failed,
  reason}}` is returned so the caller can surface a message while keeping the
  already-registered account.

  The `:unavailable` consent (portal unreachable at onboarding time) records
  consent as `"declined"` and additionally scaffolds the keyless ZAQ Router
  credential so the provider is listed — without wiring it as the active model
  config. The dashboard retry later fills in the API key.
  """

  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.UserPortal.InstallationWorker
  alias Zaq.UserPortal.Provisioner

  require Logger

  @type consent :: :accepted | :declined | :unavailable

  @doc """
  Completes bootstrap onboarding for `user` with `attrs` (email + password) and the
  given portal `consent`.

  The account registration (email + password) is committed first via
  `Zaq.Accounts.complete_registration/2`. Only then is provisioning attempted, so
  a portal failure leaves the account intact rather than blocking access.

  Returns `{:ok, user}` on success, `{:error, %Ecto.Changeset{}}` when the
  registration write itself fails, or — for `:accepted` consent whose provisioning
  fails — `{:error, {:provisioning_failed, reason}}` with the account already
  registered and consent recorded as `"declined"`.
  """
  @spec complete_bootstrap_onboarding(User.t(), map(), consent()) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:provisioning_failed, term()}}
  def complete_bootstrap_onboarding(user, attrs, consent)
      when consent in [:accepted, :declined, :unavailable] do
    with {:ok, registered_user} <- Accounts.complete_registration(user, attrs) do
      apply_consent(registered_user, consent)
    end
  end

  @doc "Redeems a Portal link for the pending bootstrap administrator and queues local settings."
  def connect_bootstrap(%User{id: id}, portal_token, password) do
    client = Zaq.UserPortal.client()

    with %User{id: ^id, must_change_password: true} = user <-
           Accounts.bootstrap_admin_pending_onboarding(),
         {:ok, connection} <- client.connect(portal_token),
         true <- InstallationWorker.valid_url?(connection.installation_url),
         {:ok, {registered, job_id}} <- register_and_enqueue(user, connection, password) do
      {:ok, registered, job_id, client.confirm_connection(connection.confirmation_token)}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :registration_failed}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_portal_response}
      _ -> {:error, :bootstrap_unavailable}
    end
  end

  defp register_and_enqueue(user, connection, password) do
    attrs = %{email: connection.email, password: password}

    Repo.transact(fn ->
      with {:ok, registered} <- Accounts.complete_registration(user, attrs),
           {:ok, job} <- enqueue_installation(registered.id, connection),
           {:ok, accepted} <-
             registered |> User.portal_consent_changeset("accepted") |> Repo.update(),
           :ok <- provision_connection(connection.litellm_api_key) do
        {:ok, {accepted, job.id}}
      end
    end)
  end

  defp enqueue_installation(admin_id, connection) do
    job =
      connection
      |> Map.take([:installation_url, :deploy_on_own_cluster])
      |> InstallationWorker.new(meta: %{"admin_id" => admin_id})

    case Oban.insert(job) do
      {:ok, _job} = queued -> queued
      {:error, _reason} -> {:error, :installation_enqueue_failed}
    end
  rescue
    _ in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :installation_enqueue_failed}
  end

  defp provision_connection(api_key) do
    provision = fn -> Provisioner.provision_with_key(%{litellm_api_key: api_key}) end

    result =
      if NodeRouter.find_node(Zaq.Engine.Supervisor) == node() and
           NodeRouter.find_node(Zaq.Agent.Supervisor) == node() do
        provision.()
      else
        # In a split deployment a remote role must see writes made by a local role.
        # A separate DB checkout keeps those writes outside the registration transaction.
        provision |> Task.async() |> Task.await(:infinity)
      end

    case result do
      {:ok, _credential} -> :ok
      {:error, _reason} -> {:error, :local_setup_failed}
    end
  end

  @doc """
  Activates the portal for an already-registered user from the dashboard retry
  flow (used when the admin declined consent during bootstrap).

  `entered_email` is used when the user has no email on file, or when the user
  explicitly provides a non-blank override (inline email-correction flow after a
  409 conflict). The email is validated up front, so an invalid address never
  reaches the portal, and both the email and the accepted consent are persisted
  **only after provisioning succeeds**. A successful portal claim and credential
  are retained if later local bootstrap fails, so retries can resume without a
  second remote claim. A failed attempt does not change the user's email/consent.

  Returns `{:ok, user}`, `{:error, %Ecto.Changeset{}}` for an invalid/blank email,
  or `{:error, reason}` when provisioning fails.
  """
  @spec activate_portal(User.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def activate_portal(%User{} = user, entered_email) do
    changeset = portal_activation_changeset(user, entered_email)

    with {:ok, email} <- fetch_valid_email(changeset),
         {:ok, _credential} <- provision_or_scaffold_on_conflict(email) do
      Repo.update(changeset)
    end
  end

  # A 409 means the email is already provisioned in the portal. Re-provisioning
  # cannot help, so guarantee the keyless ZAQ Router credential exists (the call
  # is idempotent) for the user to paste their existing key into, then surface
  # the conflict. No user email or consent is written on failure.
  defp provision_or_scaffold_on_conflict(email) do
    case Provisioner.provision_for_user(email) do
      {:ok, _credential} = ok ->
        ok

      {:error, {409, _body}} = err ->
        ensure_offline_router_credential()
        err

      {:error, _reason} = err ->
        err
    end
  end

  defp portal_activation_changeset(user, entered_email) do
    trimmed = String.trim(entered_email || "")

    # Use the entered email when the user has no email on file, or when they
    # explicitly supply a non-blank override (e.g. after a 409 email conflict).
    attrs =
      if blank?(user.email) or not blank?(trimmed) do
        %{email: trimmed, portal_consent: "accepted"}
      else
        %{portal_consent: "accepted"}
      end

    User.portal_activation_changeset(user, attrs)
  end

  defp fetch_valid_email(%Ecto.Changeset{valid?: true} = changeset),
    do: {:ok, Ecto.Changeset.fetch_field!(changeset, :email)}

  defp fetch_valid_email(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp apply_consent(user, :declined) do
    # Always scaffold the keyless ZAQ Router credential so the provider is listed
    # regardless of whether the user declined consent or the portal was unreachable.
    # The credential is best-effort and must never block consent recording.
    ensure_offline_router_credential()

    user
    |> User.portal_consent_changeset("declined")
    |> Repo.update()
  end

  defp apply_consent(user, :unavailable) do
    apply_consent(user, :declined)
  end

  defp apply_consent(user, :accepted) do
    case Provisioner.provision_for_user(user.email) do
      {:ok, _credential} ->
        user
        |> User.portal_consent_changeset("accepted")
        |> Repo.update()

      {:error, {409, _body} = reason} ->
        # The email is already registered on the portal — re-provisioning cannot
        # help, so record the distinct "portal_registered" consent (which keeps the
        # activation banner hidden) and scaffold the keyless router so the provider
        # is listed for the user to paste their existing key into.
        ensure_offline_router_credential()
        {:ok, _user} = user |> User.portal_consent_changeset("portal_registered") |> Repo.update()
        {:error, {:provisioning_failed, reason}}

      {:error, reason} ->
        # The account is already registered; keep it usable by recording declined
        # consent and scaffolding the keyless offline router (so the provider is
        # listed for the dashboard retry), then surface the provisioning failure.
        {:ok, _user} = apply_consent(user, :declined)
        {:error, {:provisioning_failed, reason}}
    end
  end

  @doc """
  Re-shows the portal activation banner after a user changes their email.

  A new email may need (re)provisioning, so consent is reset to `"declined"` to
  surface the banner — but only when the ZAQ Router has no API key yet. A fully
  provisioned user (working key) is left untouched.
  """
  @spec refresh_portal_banner_after_email_change(User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def refresh_portal_banner_after_email_change(%User{} = user) do
    if Provisioner.router_key_set?() do
      {:ok, user}
    else
      user
      |> User.portal_consent_changeset("declined")
      |> Repo.update()
    end
  end

  defp ensure_offline_router_credential do
    case Provisioner.ensure_offline_credential() do
      {:ok, _credential} ->
        :ok

      {:error, reason} ->
        Logger.warning("Offline ZAQ Router credential scaffolding failed: #{inspect(reason)}")
        :ok
    end
  end
end
