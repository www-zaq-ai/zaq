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

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.UserPortal.Provisioner

  require Logger

  @type consent :: :accepted | :declined | :unavailable

  @doc """
  Attempts portal provisioning for `email` without touching the account.

  Use this during the consent modal flow to validate the email before committing
  any account changes. Pass `:pre_provisioned` to `complete_bootstrap_onboarding/3`
  once this returns `{:ok, _}`.
  """
  @spec try_provision(String.t()) :: {:ok, term()} | {:error, term()}
  def try_provision(email) when is_binary(email) do
    Provisioner.provision_for_user(email)
  end

  @doc """
  Completes bootstrap onboarding for `user` with `attrs` (email + password) and the
  given portal `consent`.

  Returns `{:ok, user}` on success or `{:error, %Ecto.Changeset{}}` when the
  registration write fails. Use `:pre_provisioned` when portal provisioning was
  already done via `try_provision/1` — skips re-provisioning and records accepted.
  """
  @spec complete_bootstrap_onboarding(User.t(), map(), consent() | :pre_provisioned) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t()}
  def complete_bootstrap_onboarding(user, attrs, consent)
      when consent in [:accepted, :declined, :unavailable, :pre_provisioned] do
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

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

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

  # Provisioning already succeeded via try_provision/1 — just record consent.
  defp apply_consent(user, :pre_provisioned) do
    user
    |> User.portal_consent_changeset("accepted")
    |> Repo.update()
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
