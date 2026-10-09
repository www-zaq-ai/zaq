defmodule Zaq.Engine.Connect.OAuth.Binding do
  @moduledoc """
  Internal shared ownership/configuration binding and canonical completion for
  authorization-code and device attempts. Caller holds the authentication transaction
  at preparation; completion revalidates under Person/session, credential, then
  attempt locks. This is not a public authentication or grant-write capability.
  """
  import Ecto.Query
  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions, Person}
  alias Zaq.Engine.Connect.{Credential, Mutations, Snapshot}
  alias Zaq.Repo
  alias Zaq.Utils.DateUtils

  def validate_locked(attempt, provider, opts) do
    if attempt.owner_type == "person", do: validate_session(attempt, opts)
    current = if attempt.credential_id, do: lock_credential(attempt.credential_id)
    schema = attempt.__struct__

    persisted =
      Repo.one(from a in schema, where: a.id == ^attempt.id, lock: "FOR UPDATE", select: a.id)

    ensure(persisted != nil, :invalid_attempt)
    ensure(DateTime.compare(attempt.expires_at, DateUtils.now(opts)) == :gt, :invalid_attempt)
    ensure(attempt.provider == provider, :invalid_attempt)
    ensure(attempt.config_fingerprint == fingerprint(attempt.credential_id), :invalid_attempt)
    credential = candidate(attempt, current)
    ensure(credential.provider == provider and credential.auth_kind == "oauth2", :invalid_attempt)

    if attempt.owner_type == "person" do
      ensure(active_person?(attempt.owner_id) and eligible?(credential), :invalid_attempt)
    end

    credential
  end

  def replace(%{owner_type: "person", owner_id: id}, credential, material, opts),
    do: Mutations.replace_credential_grant(credential, {:person, id}, material, opts)

  def replace(attempt, credential, material, opts),
    do:
      Mutations.save_credential_configuration(
        attempt.credential_id,
        configuration_attrs(credential),
        {:replace, material},
        opts
      )

  def configuration_attrs(credential) do
    credential
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :grants])
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  def fingerprint(nil), do: :crypto.hash(:sha256, "new-credential")
  def fingerprint(id), do: Snapshot.credential(id, timestamps: false)

  def lock_credential(id),
    do:
      Repo.one(from(c in Credential, where: c.id == ^id, lock: "FOR UPDATE"), log: false) ||
        Repo.rollback(:not_found)

  def active_person?(id),
    do: Repo.exists?(from p in Person, where: p.id == ^id and p.status == "active")

  def eligible?(c),
    do:
      c.auth_kind == "oauth2" and c.secret_binding == :grant and
        c.personal_credential_policy in [:optional, :required]

  def token_material(payload) do
    Enum.reduce([:access_token, :refresh_token, :expires_at, :metadata], %{}, fn key, acc ->
      value = Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  @doc "Rejects caller transactions before network-bearing handshake operations."
  def outside_transaction,
    do: if(Repo.in_transaction?(), do: {:error, :transaction_not_allowed}, else: :ok)

  defp candidate(%{owner_type: "person"}, current), do: current

  defp candidate(attempt, _current) do
    with value when is_binary(value) <- attempt.candidate_config,
         {:ok, attrs} <- Jason.decode(value),
         changeset = Credential.changeset(%Credential{}, attrs),
         true <- changeset.valid? do
      Ecto.Changeset.apply_changes(changeset)
    else
      _ -> Repo.rollback(:invalid_attempt)
    end
  end

  defp validate_session(%{session_id: nil}, _opts), do: Repo.rollback(:invalid_attempt)

  defp validate_session(attempt, opts) do
    with {:ok, auth} <- PeopleAuth.revalidate_session(attempt.owner_id, attempt.session_id, opts),
         true <- PeoplePermissions.allowed?(auth.person, [:access_profile, :manage_credentials]) do
      :ok
    else
      _ -> Repo.rollback(:invalid_attempt)
    end
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: Repo.rollback(reason)
end
