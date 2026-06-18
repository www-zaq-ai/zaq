defmodule Zaq.UserPortal.Onboarding do
  @moduledoc """
  Owns the bootstrap onboarding flow: registration write, portal consent, and
  provisioning.

  This is the UserPortal boundary's orchestrator. Registration (email + password)
  is delegated to `Zaq.Accounts.complete_registration/2`; consent persistence and
  provisioning live here so success/failure of provisioning can drive the recorded
  consent value.

  Registration is committed **before** the portal is contacted, so a portal
  failure never blocks account creation — the admin always ends up with a usable
  ZAQ account and can complete portal activation later from the dashboard retry
  flow (`activate_portal/2`).

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
  alias Zaq.Repo
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

  @doc """
  Activates the portal for an already-registered user from the dashboard retry
  flow (used when the admin declined consent during bootstrap).

  `entered_email` is used when the user has no email on file, or when the user
  explicitly provides a non-blank override (inline email-correction flow after a
  409 conflict). The email is validated up front, so an invalid address never
  reaches the portal, and both the email and the accepted consent are persisted
  **only after provisioning succeeds** — a failed provisioning attempt commits
  nothing.

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
  # the conflict. No consent is written — a failed retry commits nothing.
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
