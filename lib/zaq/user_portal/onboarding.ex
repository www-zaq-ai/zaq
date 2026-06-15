defmodule Zaq.UserPortal.Onboarding do
  @moduledoc """
  Owns the bootstrap onboarding flow: registration write, portal consent, and
  provisioning.

  This is the UserPortal boundary's orchestrator. Registration (email + password)
  is delegated to `Zaq.Accounts.complete_registration/2`; consent persistence and
  provisioning live here so success/failure of provisioning can drive the recorded
  consent value.

  On acceptance, provisioning runs synchronously. If it fails, consent is recorded
  as `"declined"` so the dashboard retry flow (`activate_portal/2`) remains valid,
  and `{:error, {:provisioning_failed, reason}}` is returned so the caller can
  surface a message.

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
  @type pre_provisioned :: {:pre_provisioned, %{litellm_api_key: String.t()}}

  @doc """
  Claims a portal API key for `email` without touching the account.

  Use this during the consent modal flow to validate the email against the portal
  before committing any account changes — it performs the portal HTTP call only,
  with no local writes. On `{:ok, litellm}`, pass `{:pre_provisioned, litellm}` to
  `complete_bootstrap_onboarding/3`, which persists the credential and the account
  registration in a single transaction.
  """
  @spec try_provision(String.t()) :: {:ok, %{litellm_api_key: String.t()}} | {:error, term()}
  def try_provision(email) when is_binary(email) do
    Provisioner.claim_key(email)
  end

  @doc """
  Completes bootstrap onboarding for `user` with `attrs` (email + password) and the
  given portal `consent`.

  Returns `{:ok, user}` on success or `{:error, %Ecto.Changeset{}}` when the
  registration (or credential) write fails.

  Pass `{:pre_provisioned, litellm}` with the key claimed via `try_provision/1`:
  the registration write, credential write, and accepted-consent record run as a
  Sage saga inside a single DB transaction, so a failure in any step rolls the
  whole thing back rather than orphaning a credential.

  With raw `:accepted` consent, provisioning runs synchronously; if it fails the
  consent is recorded as `"declined"` and `{:error, {:provisioning_failed, reason}}`
  is returned so the caller can surface a message.
  """
  @spec complete_bootstrap_onboarding(User.t(), map(), consent() | pre_provisioned()) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:provisioning_failed, term()}}
  def complete_bootstrap_onboarding(user, attrs, {:pre_provisioned, litellm}) do
    Sage.new()
    |> Sage.run(:registration, fn _effects, _opts ->
      Accounts.complete_registration(user, attrs)
    end)
    |> Sage.run(:credential, fn _effects, _opts ->
      Provisioner.provision_with_key(litellm)
    end)
    |> Sage.run(:consent, fn %{registration: registered}, _opts ->
      registered
      |> User.portal_consent_changeset("accepted")
      |> Repo.update()
    end)
    |> Sage.transaction(Repo)
    |> case do
      {:ok, user, _effects} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

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
         {:ok, _credential} <- Provisioner.provision_for_user(email) do
      Repo.update(changeset)
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

      {:error, reason} ->
        {:ok, _user} =
          user
          |> User.portal_consent_changeset("declined")
          |> Repo.update()

        {:error, {:provisioning_failed, reason}}
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
