defmodule Zaq.Engine.Connect.OAuth.Binding do
  @moduledoc """
  Internal coordination of owner-domain APIs for both OAuth handshake lifecycles.
  Authorization delegates to PeopleCredentials.Authorization; configuration validation
  and grant completion delegate to canonical Mutations. The owning attempt module
  validates and locks its lifecycle row after the Person/session and credential locks.
  This module never queries an identity, credential or attempt schema, and does not
  implement eligibility, candidate serialization or lifecycle rules.
  """
  alias Zaq.Engine.Connect.{Credential, Mutations}
  alias Zaq.Engine.PeopleCredentials.Authorization
  alias Zaq.Repo

  @type t :: %{
          owner: Mutations.owner(),
          credential_id: pos_integer() | nil,
          session_id: Ecto.UUID.t() | nil,
          provider: String.t(),
          config_fingerprint: binary(),
          candidate_config: String.t() | nil
        }

  @doc "Builds a binding from server-derived domain values, without interpreting an attempt record."
  @spec new(
          Mutations.owner(),
          pos_integer() | nil,
          Ecto.UUID.t() | nil,
          String.t(),
          binary(),
          String.t() | nil
        ) :: t()
  def new(owner, credential_id, session_id, provider, fingerprint, candidate) do
    %{
      owner: owner,
      credential_id: credential_id,
      session_id: session_id,
      provider: provider,
      config_fingerprint: fingerprint,
      candidate_config: candidate
    }
  end

  @doc "Coordinates validation of an explicit server-derived binding inside the caller transaction."
  @spec validate_locked(t(), keyword()) :: Credential.t()
  def validate_locked(binding, opts) do
    validate_session(binding, opts)

    case Mutations.validate_oauth_configuration(binding) do
      {:ok, credential} -> credential
      _ -> Repo.rollback(:invalid_attempt)
    end
  end

  @doc "Completes an already validated binding through the canonical grant writer."
  @spec replace(t(), Credential.t(), map(), keyword()) :: Mutations.result()
  def replace(%{owner: {:person, id}}, credential, material, opts),
    do: Mutations.replace_credential_grant(credential, {:person, id}, material, opts)

  def replace(%{owner: :org} = binding, credential, material, opts),
    do:
      Mutations.save_credential_configuration(
        binding.credential_id,
        Credential.oauth_configuration_attrs(credential),
        {:replace, material},
        opts
      )

  defp validate_session(%{owner: :org}, _opts), do: :ok
  defp validate_session(%{session_id: nil}, _opts), do: Repo.rollback(:invalid_attempt)

  defp validate_session(%{owner: {:person, id}, session_id: session_id}, opts) do
    case Authorization.revalidate_session(id, session_id, opts) do
      {:ok, _auth} -> :ok
      _ -> Repo.rollback(:invalid_attempt)
    end
  end
end
