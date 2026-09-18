defmodule Zaq.Engine.Connect.MutationEvents do
  @moduledoc """
  Transactional persistence and secret-free notification contract for Connect mutations.

  Version 1 carries a UUID `event_id`, integer `credential_id`, nullable integer
  `grant_id`/`owner_id`, nullable `owner_type`, fixed `kind` and UTC `occurred_at`.
  Credential events affect every scope, including grants removed by its cascade.
  Grant events identify the owner even after removal. No provider metadata, secrets,
  schemas or artificial monotonic revision cross the durable or routed boundary.

  Jobs share the mutation's Repo transaction, including outer transactions. Callers
  must use these persistence functions rather than enqueue after committing. Test
  callers must use manual Oban, since inline execution precedes commit.

  The dedicated queue is deliberately unconsumed until an actual Agent receiver and
  owning-node fanout ship. Delivery is synchronous and only explicit `:ok` succeeds;
  this is not consumer acknowledgment or a fanout guarantee. Retries retain the UUID,
  may duplicate or reorder events, and future consumers must read current state.
  Activation must explicitly address backlog retention/replay and exhausted jobs;
  there is no silent pruning or historical replay guarantee here.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Zaq.Agent.Events
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEventWorker}
  alias Zaq.Repo

  @credential_kinds ~w(credential_created credential_updated credential_deleted)
  @grant_kinds ~w(grant_created grant_replaced grant_revoked grant_deleted grant_tokens_updated)
  @keys ~w(version event_id credential_id grant_id owner_type owner_id kind occurred_at)

  @doc "Persists a Connect changeset and its notification atomically; empty updates are silent."
  @spec persist(Changeset.t(), String.t()) :: {:ok, Credential.t() | Grant.t()} | {:error, term()}
  def persist(%Changeset{} = changeset, kind) do
    Repo.transaction(fn -> persist_and_enqueue(changeset, kind) end)
  end

  defp persist_and_enqueue(changeset, kind) do
    case Repo.insert_or_update(changeset) do
      {:ok, record} ->
        if changeset.data.__meta__.state == :built or map_size(changeset.changes) > 0,
          do: enqueue(record, kind)

        record

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc "Locks and reloads the deletion target so the event captures its persisted owner."
  @spec delete(Credential.t() | Grant.t()) :: {:ok, Credential.t() | Grant.t()} | {:error, term()}
  def delete(%schema{id: id}) when schema in [Credential, Grant] do
    Repo.transaction(fn ->
      record = Repo.one(from r in schema, where: r.id == ^id, lock: "FOR UPDATE")
      if is_nil(record), do: Repo.rollback(:not_found)

      deleted = Repo.delete!(Changeset.change(record))
      kind = if schema == Credential, do: "credential_deleted", else: "grant_deleted"
      enqueue(deleted, kind)
      deleted
    end)
  end

  @doc "Enqueues an already captured grant dependency inside a lifecycle transaction, including unchanged survivor slots."
  @spec notify_dependency(Grant.t(), String.t()) :: :ok
  def notify_dependency(%Grant{} = grant, kind) do
    if not Repo.in_transaction?(),
      do: raise(ArgumentError, "dependency notification requires a transaction")

    enqueue(grant, kind)
  end

  defp enqueue(record, kind) do
    payload =
      record
      |> identity()
      |> Map.merge(%{
        "version" => 1,
        "event_id" => Ecto.UUID.generate(),
        "kind" => kind,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    with :ok <- validate(payload),
         {:ok, _job} <- payload |> MutationEventWorker.new() |> Oban.insert() do
      :ok
    else
      _ -> Repo.rollback(:mutation_event_enqueue_failed)
    end
  rescue
    _ -> Repo.rollback(:mutation_event_enqueue_failed)
  end

  defp identity(%Credential{id: id}),
    do: %{"credential_id" => id, "grant_id" => nil, "owner_type" => nil, "owner_id" => nil}

  defp identity(%Grant{} = grant),
    do: %{
      "credential_id" => grant.credential_id,
      "grant_id" => grant.id,
      "owner_type" => grant.owner_type,
      "owner_id" => grant.owner_id
    }

  @doc "Validates the complete durable allowlist before dispatch, rejecting additional keys."
  @spec validate(term()) :: :ok | {:error, :invalid_mutation_event}
  def validate(
        %{
          "version" => 1,
          "event_id" => event_id,
          "credential_id" => id,
          "occurred_at" => timestamp
        } = payload
      )
      when map_size(payload) == 8 do
    with true <- Enum.all?(@keys, &Map.has_key?(payload, &1)),
         true <- positive_id?(id),
         {:ok, ^event_id} <- Ecto.UUID.cast(event_id),
         true <- is_binary(timestamp),
         {:ok, _, 0} <- DateTime.from_iso8601(timestamp),
         true <- valid_identity?(payload) do
      :ok
    else
      _ -> {:error, :invalid_mutation_event}
    end
  end

  def validate(_), do: {:error, :invalid_mutation_event}

  defp valid_identity?(%{
         "kind" => kind,
         "grant_id" => nil,
         "owner_type" => nil,
         "owner_id" => nil
       }),
       do: kind in @credential_kinds

  defp valid_identity?(%{
         "kind" => kind,
         "grant_id" => id,
         "owner_type" => owner,
         "owner_id" => owner_id
       }) do
    kind in @grant_kinds and positive_id?(id) and
      ((owner in ["org", "user"] and (is_nil(owner_id) or is_integer(owner_id))) or
         (owner == "person" and positive_id?(owner_id)))
  end

  defp positive_id?(id), do: is_integer(id) and id > 0

  @doc "Synchronously delivers a validated notification through the existing Agent routing boundary."
  @spec deliver(term(), keyword()) :: :ok | {:error, atom()}
  def deliver(payload, opts \\ []) do
    with :ok <- validate(payload) do
      case Events.build_and_dispatch_invoke_event(payload, :connect_credential_mutated,
             node_router: Keyword.get(opts, :node_router, Zaq.NodeRouter)
           ) do
        %Zaq.Event{response: :ok} -> :ok
        _ -> {:error, :mutation_event_delivery_failed}
      end
    end
  rescue
    _ -> {:error, :mutation_event_delivery_failed}
  catch
    _, _ -> {:error, :mutation_event_delivery_failed}
  end
end
