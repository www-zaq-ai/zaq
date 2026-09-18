defmodule Zaq.Engine.Connect.PersonCredentials do
  @moduledoc """
  Write-only management of the authenticated Person's canonical credential slots.

  ## Domain boundary — authentication is owned by PeopleAuth

  `Zaq.Engine.PeopleCredentials` authenticates bearer sessions and authorizes
  permissions before calling this module. A Person struct is not an authentication
  token; this module remains the Connect-domain implementation and independently
  reloads literal identity for storage safety. Actor maps, browser IDs, BO Users and
  machine permission flags are not accepted. Every call reloads the literal active Person,
  without alias resolution; writes recheck after acquiring the credential lock.
  Concurrent identity deletion after that check can still orphan encrypted material
  (the approved storage limitation); IDs must not be reused.

  Reads select only allowlisted configuration fields and the caller's slot status and
  expiration, never global availability, schemas, secrets, OAuth client settings or
  metadata. Status is stored lifecycle plus local expiration, not provider verification
  or runtime credential resolution. No provider account metadata is approved yet.

  Only grant-owned optional/required configurations are listed or replaceable.
  A known retained own grant remains readable and cleanable after policy/binding
  changes. Cleanup of absent slots is idempotent, including disabled configurations.
  Revoke clears secrets but retains a revoked slot; remove deletes it and restores
  absence semantics for the later resolver. Cleanup still requires an active Person.

  Writes accept API-key or JWT material via `Mutations`' auth-kind allowlists, plus
  expiration. OAuth starts only through the authenticated `PeopleCredentials` gateway,
  which creates opaque one-use `OAuthAttempts`; People never supply OAuth client configuration. Ownership and all configuration
  fields are server-derived. Success contains only credential ID/status; errors are
  fixed atoms, never changesets, provider payloads, or submitted params. Writes and
  their secret-free `MutationEvents` jobs commit or roll back together.
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect.{Credential, CredentialStatuses, Mutations, OAuthAttempts}
  alias Zaq.Repo

  @type mutation_result :: %{credential_id: pos_integer(), status: String.t()}
  @type error ::
          :encryption_failed
          | :invalid_material
          | :not_found
          | :unauthorized
          | :unsupported_auth_kind
          | :mutation_event_enqueue_failed
  @type result :: {:ok, CredentialStatuses.summary() | mutation_result()} | {:error, error()}

  @doc false
  @spec prepare_oauth(Person.t(), Ecto.UUID.t(), pos_integer(), keyword()) :: result()
  def prepare_oauth(authenticated_person, session_id, credential_id, opts \\ []) do
    with {:ok, person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      OAuthAttempts.prepare_person(person, session_id, credential_id, opts)
    end
  end

  @doc "Lists eligible configurations with only the authenticated Person's own status."
  @spec list_available(Person.t()) ::
          {:ok, [CredentialStatuses.summary()]} | {:error, :unauthorized}
  def list_available(authenticated_person) do
    with {:ok, person} <- current_person(authenticated_person) do
      {:ok, CredentialStatuses.list_person(person.id)}
    end
  end

  @doc "Returns an eligible configuration's own status, or a known retained own grant."
  @spec get_own_status(Person.t(), pos_integer()) :: result()
  def get_own_status(authenticated_person, credential_id) do
    with {:ok, person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      CredentialStatuses.get_person(person.id, credential_id)
    end
  end

  @doc "Replaces complete API-key/JWT material in the authenticated Person's own slot."
  @spec put_own_authentication(Person.t(), pos_integer(), map(), keyword()) :: result()
  def put_own_authentication(authenticated_person, credential_id, material, opts \\ []) do
    mutate(authenticated_person, credential_id, fn credential, owner ->
      unless eligible?(credential), do: Repo.rollback(:not_found)

      unless credential.auth_kind in ["api_key", "jwt_bearer"],
        do: Repo.rollback(:unsupported_auth_kind)

      Mutations.replace_credential_grant(credential, owner, material, opts)
    end)
  end

  @doc "Clears own secrets and retains a revoked slot; absent slots remain absent."
  @spec revoke_own_grant(Person.t(), pos_integer()) :: result()
  def revoke_own_grant(authenticated_person, credential_id) do
    mutate(authenticated_person, credential_id, &Mutations.revoke_credential_grant/2)
  end

  @doc "Deletes only the own slot, restoring absence; repeated removal succeeds."
  @spec remove_own_grant(Person.t(), pos_integer()) :: result()
  def remove_own_grant(authenticated_person, credential_id) do
    mutate(authenticated_person, credential_id, &Mutations.remove_credential_grant/2)
  end

  defp mutate(authenticated_person, credential_id, operation) do
    with {:ok, _person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      Repo.transaction(fn ->
        credential =
          Repo.one(from c in Credential, where: c.id == ^credential_id, lock: "FOR UPDATE") ||
            Repo.rollback(:not_found)

        person = unwrap(current_person(authenticated_person))

        credential
        |> operation.({:person, person.id})
        |> unwrap()
        |> Map.take([:credential_id, :status])
      end)
    end
  end

  defp current_person(%Person{id: id, __meta__: %{state: :loaded}})
       when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 do
    case Repo.get_by(Person, id: id, status: "active") do
      nil -> {:error, :unauthorized}
      person -> {:ok, person}
    end
  end

  defp current_person(_), do: {:error, :unauthorized}

  defp valid_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807, do: :ok
  defp valid_id(_), do: {:error, :not_found}

  defp eligible?(credential),
    do:
      credential.secret_binding == :grant and
        credential.personal_credential_policy in [:optional, :required]

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
