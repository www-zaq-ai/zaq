defmodule Zaq.Engine.Connect.Refresh do
  @moduledoc """
  Shared grant refresh lease and conditional token-cache persistence boundary.

  A 120-second DB lease coordinates nodes and bounds crash/error recovery. Contenders
  return `:refresh_busy`; there is no in-call retry. Failed requests retain the lease
  as cooldown. Expired leases may be reclaimed, and a late former holder cannot save.
  Network work is never run within a Repo transaction. Short local transactions lock
  credential then grant, and compare raw stored material/configuration, including
  ciphertext, before token use and persistence. Literal active Person checks never
  follow aliases. Concurrent deletion after the final identity check is the accepted
  storage limitation; no Person FK, trigger or identity guard is introduced.

  This internal boundary accepts the existing Connect provider dispatcher and writer;
  it does not implement providers or select credential policy. Runtime schemas are
  secret-bearing and must not be returned to transports.

  The runtime resolver may pass `:expected_fingerprint` captured under its selection
  locks. Cached reload and refresh claim check this raw snapshot before consuming
  tokens, closing selection-to-preparation replacement races without a revision layer.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect.{Credential, Grant, Snapshot}
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.DateUtils

  @lease_seconds 120
  @ignored [:__meta__, :credential, :refresh_claim, :refresh_claim_until, :updated_at]

  @doc "Runs one refresh using the existing provider and persistence functions."
  @spec run(Grant.t(), function(), function(), keyword()) :: {:ok, Grant.t()} | {:error, atom()}
  def run(grant, dispatch, persist, opts) do
    case run_refresh(grant, dispatch, persist, opts) do
      {:ok, _} = result -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_refresh_response}
    end
  end

  defp run_refresh(grant, dispatch, persist, opts) do
    if Repo.in_transaction?() do
      {:error, :refresh_requires_committed_state}
    else
      with {:ok, snapshot} <- claim(grant, opts),
           {:ok, {current, credential}} <- verify(snapshot, opts),
           {:ok, payload} <- request(dispatch, current, credential, opts) do
        finish(snapshot, persist, payload, opts)
      end
    end
  end

  defp finish(snapshot, persist, payload, opts) do
    Repo.transaction(fn ->
      {current, credential} = checked(snapshot, opts)
      result = persist.(current, credential, payload, opts) |> safe_persistence() |> unwrap()
      result |> Changeset.change(refresh_claim: nil, refresh_claim_until: nil) |> Repo.update!()
      Repo.reload!(result)
    end)
  end

  @doc "Reloads an eligible grant before local cache use, optionally checking the resolver's raw expected fingerprint."
  @spec current(Grant.t(), keyword()) :: {:ok, Grant.t()} | {:error, atom()}
  def current(grant, opts \\ []) do
    Repo.transaction(fn ->
      {current, _credential} = lock_current(grant)
      validate_expected_snapshot(current, opts)
      current
    end)
  end

  @doc "Guards the legacy direct cache writer. Canonical rows require claimed refresh."
  @spec cache(Grant.t(), function()) :: {:ok, Grant.t()} | {:error, term()}
  def cache(grant, persist) do
    Repo.transaction(fn ->
      {current, _} = lock_current(grant)
      ensure(current.resource_type != "connect_credential", :canonical_refresh_required)
      ensure(same_material?(grant, current), :stale_grant)
      unwrap(persist.(current))
    end)
  end

  defp claim(grant, opts) do
    Repo.transaction(fn ->
      {current, _credential} = lock_current(grant)
      validate_expected_snapshot(current, opts)
      ensure(current.auth_kind == "oauth2", :unsupported)
      ensure(present?(current.refresh_token), :authentication_required)

      ensure(
        is_nil(current.refresh_claim_until) or
          DateTime.compare(current.refresh_claim_until, now(opts)) != :gt,
        :refresh_busy
      )

      current
      |> Changeset.change(
        refresh_claim: Ecto.UUID.generate(),
        refresh_claim_until: DateTime.add(now(opts), @lease_seconds, :second)
      )
      |> Repo.update!()

      %{grant: current, fingerprint: fingerprint(current.id)}
    end)
  end

  defp verify(snapshot, opts), do: Repo.transaction(fn -> checked(snapshot, opts) end)

  defp checked(snapshot, opts) do
    {grant, credential} = lock_current(snapshot.grant)
    ensure(fingerprint(grant.id) == snapshot.fingerprint, :stale_grant)
    ensure(present?(grant.refresh_token), :authentication_required)

    ensure(
      not is_nil(grant.refresh_claim_until) and
        DateTime.compare(grant.refresh_claim_until, now(opts)) == :gt,
      :stale_grant
    )

    {grant, credential}
  end

  defp lock_current(%Grant{id: id, credential_id: credential_id}) do
    credential = Repo.one(from c in Credential, where: c.id == ^credential_id, lock: "FOR UPDATE")
    ensure(not is_nil(credential), :not_found)

    grant =
      Repo.one(
        from g in Grant,
          where: g.id == ^id and g.credential_id == ^credential_id,
          lock: "FOR UPDATE"
      )

    ensure(not is_nil(grant), :not_found)
    ensure(grant.status != "revoked", :revoked)
    ensure(grant.status in ["active", "expired"], :authentication_required)
    validate_person(grant)
    validate_configuration(grant, credential)
    validate_client_secret(credential)
    {grant, credential}
  end

  defp validate_client_secret(%Credential{client_secret: nil, id: id}) do
    stored? =
      Repo.exists?(
        from c in "connect_credentials", where: c.id == ^id and not is_nil(c.client_secret)
      )

    ensure(not stored?, :authentication_required)
  end

  defp validate_client_secret(_), do: :ok

  defp validate_person(%Grant{owner_type: "person", owner_id: id}) do
    ensure(
      Repo.exists?(from p in Person, where: p.id == ^id and p.status == "active"),
      :person_unavailable
    )
  end

  defp validate_person(_), do: :ok

  defp validate_configuration(%Grant{resource_type: "connect_credential"} = grant, credential) do
    ensure(Grant.compatible_configuration?(grant, credential), :stale_grant)
  end

  defp validate_configuration(_, _), do: :ok

  @doc "Internal raw grant/config snapshot for a caller holding the credential/grant locks. Never serialize."
  @spec fingerprint(pos_integer()) :: binary()
  def fingerprint(id), do: Snapshot.grant_with_credential(id)

  # Optional selection guard supplied by the resolver. It is checked before cached
  # use and again before claiming HTTP, using the existing raw snapshot infrastructure.
  defp validate_expected_snapshot(grant, opts) do
    case Keyword.fetch(opts, :expected_fingerprint) do
      {:ok, expected} -> ensure(fingerprint(grant.id) == expected, :stale_grant)
      :error -> :ok
    end
  end

  defp request(dispatch, grant, credential, opts) do
    case dispatch.(grant, credential, opts) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, :unsupported} -> {:error, :unsupported}
      _ -> {:error, :refresh_failed}
    end
  rescue
    _ -> {:error, :refresh_failed}
  catch
    _, _ -> {:error, :refresh_failed}
  end

  defp same_material?(left, right) do
    fields = [:access_token, :refresh_token, :api_key, :private_key]

    left =
      Enum.reduce(fields, left, fn key, acc ->
        case EncryptedString.decrypt(Map.get(acc, key)) do
          {:ok, value} -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    Map.drop(left, @ignored) == Map.drop(right, @ignored)
  end

  defp safe_persistence({:ok, _} = result), do: result

  defp safe_persistence({:error, reason})
       when reason in [:encryption_failed, :mutation_event_enqueue_failed], do: {:error, reason}

  defp safe_persistence(_), do: {:error, :invalid_refresh_response}
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp now(opts),
    do: opts |> DateUtils.now() |> DateTime.truncate(:second)

  defp ensure(valid?, reason) do
    unless valid?, do: Repo.rollback(reason)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
