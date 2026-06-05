defmodule Zaq.UserPortal.Onboarding do
  @moduledoc """
  Owns the bootstrap onboarding flow: registration write, portal consent, and
  provisioning.

  This is the UserPortal boundary's orchestrator. Registration (email + password)
  is delegated to `Zaq.Accounts.complete_registration/2`; consent persistence and
  provisioning live here so success/failure of provisioning can drive the recorded
  consent value.

  On acceptance, provisioning runs synchronously. If it fails, consent is recorded
  as `"declined"` so the dashboard retry flow (`Provisioner.provision_for_existing_user/1`)
  remains valid, and `{:error, {:provisioning_failed, reason}}` is returned so the
  caller can surface a message.
  """

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.UserPortal.Provisioner

  @type consent :: :accepted | :declined

  @doc """
  Completes bootstrap onboarding for `user` with `attrs` (email + password) and the
  given portal `consent`.

  Returns `{:ok, user}` on success, `{:error, %Ecto.Changeset{}}` when the
  registration write fails, or `{:error, {:provisioning_failed, reason}}` when the
  user accepted but provisioning failed (registration still persisted; consent
  recorded as declined).
  """
  @spec complete_bootstrap_onboarding(User.t(), map(), consent()) ::
          {:ok, User.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:provisioning_failed, term()}}
  def complete_bootstrap_onboarding(user, attrs, consent)
      when consent in [:accepted, :declined] do
    with {:ok, registered_user} <- Accounts.complete_registration(user, attrs) do
      apply_consent(registered_user, consent)
    end
  end

  defp apply_consent(user, :declined) do
    user
    |> User.portal_consent_changeset("declined")
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
end
