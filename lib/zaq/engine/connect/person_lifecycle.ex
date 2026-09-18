defmodule Zaq.Engine.Connect.PersonLifecycle do
  @moduledoc """
  Connect-owned Person secret lifetime, invoked by Accounts inside its identity transaction.

  Locks credential IDs ascending before grant rows, then OAuth attempts. Accounts takes
  its existing advisory/Person locks first; Connect writers never acquire those locks.
  Only identity projections are loaded: deletion and owner transfer never decrypt or
  rewrite ciphertext. A survivor slot wins in every status, otherwise the first loser
  in persisted ID order transfers. Original identities' attempts are cancelled, not aliased.

  Reconciliation removes missing *literal* owners, not inactive People. IDs must never
  be reused. No Person FK/trigger/guard prevents a late concurrent orphan; subsequent
  bounded passes erase it. This is eventual cleanup, not synchronous erasure.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEvents, OAuthAttempt}
  alias Zaq.Repo

  @grant_identity [:id, :credential_id, :resource_type, :resource_id, :owner_type, :owner_id]

  @doc "Deletes Person-owned material in the caller's transaction; returns only counts."
  @spec delete_people([pos_integer()]) :: map()
  def delete_people(ids) do
    require_transaction!()
    grants = lock_people_grants(ids)
    Enum.each(grants, &delete_grant/1)
    %{grants_deleted: length(grants), attempts_deleted: cancel_attempts(ids)}
  end

  @doc "Reconciles a persisted merge group in Accounts' transaction, retaining survivor slots."
  @spec merge_people(pos_integer(), [pos_integer()]) :: :ok
  def merge_people(survivor_id, loser_ids) do
    require_transaction!()
    ids = [survivor_id | loser_ids]

    ids
    |> lock_people_grants()
    |> Enum.group_by(& &1.credential_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_credential_id, grants} -> merge_slots(grants, survivor_id) end)

    cancel_attempts(ids)
    :ok
  end

  defp lock_people_grants(ids) do
    grants = from g in Grant, where: g.owner_type == "person" and g.owner_id in ^ids
    attempts = from a in OAuthAttempt, where: a.owner_type == "person" and a.owner_id in ^ids
    credential_ids = Repo.all(from g in grants, select: g.credential_id)
    attempt_credentials = Repo.all(from a in attempts, select: a.credential_id)
    locked = lock_credentials(credential_ids ++ attempt_credentials)

    Repo.all(
      from g in grants,
        where: g.credential_id in ^locked,
        order_by: g.id,
        lock: "FOR UPDATE",
        select: struct(g, ^@grant_identity)
    )
  end

  defp lock_credentials(ids) do
    Repo.all(
      from c in Credential,
        where: c.id in ^Enum.reject(ids, &is_nil/1),
        order_by: c.id,
        lock: "FOR UPDATE",
        select: c.id
    )
  end

  defp merge_slots(grants, survivor_id) do
    ordered = Enum.sort_by(grants, &{&1.owner_id != survivor_id, &1.owner_id, &1.id})
    [winner | rest] = ordered

    if winner.owner_id == survivor_id do
      if rest != [], do: MutationEvents.notify_dependency(winner, "grant_replaced")
    else
      MutationEvents.notify_dependency(winner, "grant_deleted")

      winner
      |> Grant.transfer_owner_changeset(survivor_id)
      |> MutationEvents.persist("grant_created")
      |> unwrap!()
    end

    Enum.each(rest, &delete_grant/1)
  end

  defp delete_grant(grant) do
    Repo.delete!(Changeset.change(grant), log: false)
    MutationEvents.notify_dependency(grant, "grant_deleted")
  end

  defp cancel_attempts(ids) do
    from(a in OAuthAttempt,
      where: a.owner_type == "person" and a.owner_id in ^ids,
      order_by: a.id,
      lock: "FOR UPDATE",
      select: struct(a, [:id])
    )
    |> Repo.all()
    |> delete_attempts()
  end

  defp delete_attempts(attempts) do
    Enum.each(attempts, &Repo.delete!(Changeset.change(&1), log: false))
    length(attempts)
  end

  @doc """
  One idempotent page, at most `limit` grants and `limit` attempts (default 100, max 500).
  `after: %{grant_id: integer, attempt_id: string}` resumes a stable ID keyset; omit it
  to restart. `now:` is a trusted UTC cutoff. Continuation contains internal row cursors,
  never telemetry labels. Expired attempts (including encrypted new admin
  candidates with no credential ID) and missing Person attempts are removed.
  All predicates are rechecked under locks; rows whose owner now exists are retained.
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, atom()}
  def reconcile(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    cursor = Keyword.get(opts, :after, %{grant_id: 0, attempt_id: ""})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if valid_batch?(limit, cursor, now) do
      Repo.transaction(fn -> reconcile_page(limit, cursor, now) end)
    else
      {:error, :invalid_batch}
    end
  end

  defp valid_batch?(limit, %{grant_id: grant, attempt_id: attempt}, %DateTime{}) do
    is_integer(limit) and limit in 1..500 and is_integer(grant) and grant >= 0 and
      is_binary(attempt)
  end

  defp valid_batch?(_, _, _), do: false

  defp orphan_grants do
    from g in Grant,
      as: :grant,
      where: g.owner_type == "person" and g.resource_type == "connect_credential",
      where: not exists(from p in Person, where: p.id == parent_as(:grant).owner_id)
  end

  defp stale_attempts(now) do
    from a in OAuthAttempt,
      as: :attempt,
      where:
        a.expires_at <= ^now or
          (a.owner_type == "person" and
             not exists(from p in Person, where: p.id == parent_as(:attempt).owner_id))
  end

  defp reconcile_page(limit, cursor, now) do
    grants =
      Repo.all(
        from g in orphan_grants(),
          where: g.id > ^cursor.grant_id,
          order_by: g.id,
          limit: ^limit,
          select: %{id: g.id, credential_id: g.credential_id}
      )

    attempts =
      Repo.all(
        from a in stale_attempts(now),
          where: a.id > ^cursor.attempt_id,
          order_by: a.id,
          limit: ^limit,
          select: %{id: a.id, credential_id: a.credential_id}
      )

    lock_credentials(Enum.map(grants ++ attempts, & &1.credential_id))
    grant_ids = Enum.map(grants, & &1.id)
    attempt_ids = Enum.map(attempts, & &1.id)

    # Fresh statements after the credential wait recheck literal ownership. No
    # SKIP LOCKED: a skipped row must not disappear behind the returned keyset.
    locked_grants =
      Repo.all(
        from g in orphan_grants(),
          where: g.id in ^grant_ids,
          order_by: g.id,
          lock: "FOR UPDATE",
          select: struct(g, ^@grant_identity)
      )

    Enum.each(locked_grants, &delete_grant/1)

    locked_attempts =
      Repo.all(
        from a in stale_attempts(now),
          where: a.id in ^attempt_ids,
          order_by: a.id,
          lock: "FOR UPDATE",
          select: struct(a, [:id])
      )

    %{
      grants_deleted: length(locked_grants),
      attempts_deleted: delete_attempts(locked_attempts),
      continuation: %{
        grant_id: last_id(grants, cursor.grant_id),
        attempt_id: last_id(attempts, cursor.attempt_id)
      }
    }
  end

  defp last_id([], previous), do: previous
  defp last_id(rows, _previous), do: List.last(rows).id
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, _}), do: Repo.rollback(:connect_lifecycle_failed)

  defp require_transaction! do
    if not Repo.in_transaction?(),
      do: raise(ArgumentError, "Person lifecycle requires an identity transaction")
  end
end
