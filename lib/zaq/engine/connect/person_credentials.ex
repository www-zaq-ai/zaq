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
  expiration. OAuth uses `start_oauth/3` or `reconnect_oauth/3` and opaque one-use
  `OAuthAttempts`; People never supply OAuth client configuration. Ownership and all configuration
  fields are server-derived. Success contains only credential ID/status; errors are
  fixed atoms, never changesets, provider payloads, or submitted params. Writes and
  their secret-free `MutationEvents` jobs commit or roll back together.
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect.{Credential, Grant, Mutations, OAuthAttempts}
  alias Zaq.Repo

  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Starts a one-use OAuth attempt for the trusted authenticated Person's own slot."
  @spec start_oauth(Person.t(), pos_integer(), keyword()) :: result()
  def start_oauth(authenticated_person, credential_id, opts \\ []) do
    with {:ok, person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      OAuthAttempts.start_person(person, credential_id, opts)
    end
  end

  @doc "Starts a fresh OAuth attempt; the previous grant remains until successful completion."
  @spec reconnect_oauth(Person.t(), pos_integer(), keyword()) :: result()
  def reconnect_oauth(authenticated_person, credential_id, opts \\ []),
    do: start_oauth(authenticated_person, credential_id, opts)

  @doc false
  @spec prepare_oauth(Person.t(), Ecto.UUID.t(), pos_integer(), keyword()) :: result()
  def prepare_oauth(authenticated_person, session_id, credential_id, opts \\ []) do
    with {:ok, person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      OAuthAttempts.prepare_person(person, session_id, credential_id, opts)
    end
  end

  @doc "Lists eligible configurations with only the authenticated Person's own status."
  @spec list_available(Person.t()) :: {:ok, [map()]} | {:error, :unauthorized}
  def list_available(authenticated_person) do
    with {:ok, person} <- current_person(authenticated_person) do
      rows =
        person.id
        |> summaries()
        |> where(
          [c],
          c.secret_binding == :grant and c.personal_credential_policy in [:optional, :required]
        )
        |> order_by([c], asc: c.name, asc: c.id)
        |> Repo.all()

      {:ok, Enum.map(rows, &status/1)}
    end
  end

  @doc "Returns an eligible configuration's own status, or a known retained own grant."
  @spec get_own_status(Person.t(), pos_integer()) :: result()
  def get_own_status(authenticated_person, credential_id) do
    with {:ok, person} <- current_person(authenticated_person),
         :ok <- valid_id(credential_id) do
      query =
        person.id
        |> summaries()
        |> where([c, g], c.id == ^credential_id)
        |> where(
          [c, g],
          (c.secret_binding == :grant and c.personal_credential_policy in [:optional, :required]) or
            not is_nil(g.id)
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, status(row)}
      end
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
    case Repo.one(from p in Person, where: p.id == ^id and p.status == "active") do
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

  defp summaries(person_id) do
    from c in Credential,
      left_join: g in Grant,
      on:
        g.credential_id == c.id and g.resource_type == "connect_credential" and
          g.owner_type == "person" and g.owner_id == ^person_id,
      select: %{
        credential_id: c.id,
        name: c.name,
        provider: c.provider,
        auth_kind: c.auth_kind,
        personal_credential_policy: c.personal_credential_policy,
        status: g.status,
        expires_at: g.expires_at
      }
  end

  defp status(%{status: nil} = row), do: %{row | status: "absent"}

  defp status(%{status: "active", expires_at: %DateTime{} = expiry} = row) do
    if DateTime.compare(expiry, DateTime.utc_now()) == :gt,
      do: row,
      else: %{row | status: "expired"}
  end

  defp status(row), do: row

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
