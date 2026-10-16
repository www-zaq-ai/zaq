defmodule Zaq.Engine.Conversations.ExecutionLifecycle do
  @moduledoc """
  Persists private execution state within Conversations' preparation/authorization/finalization
  transactions. Callers hold the admitted-message lock; this module never creates
  public messages, transcript placements, accounting jobs or delivery attempts.
  """

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Identity.ExecutionActor
  alias Zaq.Repo

  import Ecto.Query

  @doc "Selects an exact input-bound execution; input-only compatibility never guesses among records."
  @spec fetch(Message.t(), Ecto.UUID.t() | nil) ::
          {:ok, ExecutionRecord.t() | nil} | {:error, term()}
  def fetch(input, execution_id \\ nil) do
    query = from e in ExecutionRecord, where: e.user_message_id == ^input.id

    case execution_id do
      nil ->
        select_execution(Repo.all(from e in query, limit: 2))

      id ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             %ExecutionRecord{} = execution <- Repo.one(from e in query, where: e.id == ^id) do
          {:ok, execution}
        else
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp select_execution([]), do: {:ok, nil}
  defp select_execution([execution]), do: {:ok, execution}
  defp select_execution(_), do: {:error, :ambiguous_execution}

  @doc "Reserves one root answer UUID under the caller's admitted-input lock, without creating content."
  def reserve_answer(input, execution_id) do
    case fetch(input, execution_id) do
      {:ok, nil} -> reserve_legacy_answer(input)
      {:ok, execution} -> reserve_root_answer(execution)
      error -> error
    end
  end

  defp reserve_root_answer(%ExecutionRecord{root_execution_id: root}) when not is_nil(root),
    do: {:error, :input_not_root}

  defp reserve_root_answer(%ExecutionRecord{reserved_answer_message_id: id} = execution)
       when not is_nil(id),
       do: {:ok, answer_binding(id, execution.public_answer_message_id)}

  defp reserve_root_answer(%ExecutionRecord{status: "completed"} = execution),
    do: persist_reservation(execution, execution.public_answer_message_id)

  defp reserve_root_answer(%ExecutionRecord{status: "pending", admitted_at: nil}),
    do: {:error, :admission_required}

  defp reserve_root_answer(%ExecutionRecord{status: "pending"} = execution),
    do: persist_reservation(execution, Ecto.UUID.generate())

  defp reserve_root_answer(_execution), do: {:error, :terminal_request}

  defp persist_reservation(execution, id) do
    with {:ok, execution} <-
           execution |> ExecutionRecord.reservation_changeset(id) |> Repo.update() do
      {:ok, answer_binding(id, execution.public_answer_message_id)}
    end
  end

  defp reserve_legacy_answer(input) do
    metadata = input.metadata || %{}

    with {:ok, persisted} <- legacy_answer_id(input, metadata["execution_status"]) do
      reserve_legacy_answer(input, metadata, persisted)
    end
  end

  defp reserve_legacy_answer(input, metadata, persisted) do
    reserved = metadata["reserved_answer_message_id"]

    cond do
      not is_nil(reserved) ->
        validate_legacy_reservation(input, reserved, persisted)

      metadata["execution_status"] == "pending" or not is_nil(persisted) ->
        id = persisted || Ecto.UUID.generate()

        with {:ok, _input} <-
               input
               |> Ecto.Changeset.change(
                 metadata: Map.put(metadata, "reserved_answer_message_id", id)
               )
               |> Repo.update() do
          {:ok, answer_binding(id, persisted)}
        end

      true ->
        {:error, :terminal_request}
    end
  end

  defp legacy_answer_id(input, "completed") do
    query =
      from answer in Message,
        where:
          answer.conversation_id == ^input.conversation_id and answer.role == "assistant" and
            fragment("?->>'in_reply_to_message_id' = ?", answer.metadata, ^input.id),
        select: answer.id,
        limit: 2

    case Repo.all(query) do
      [id] -> {:ok, id}
      _ -> {:error, :answer_identity_conflict}
    end
  end

  defp legacy_answer_id(_input, _status), do: {:ok, nil}

  defp validate_legacy_reservation(input, id, persisted) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- id != input.id,
         true <- is_nil(persisted) or id == persisted do
      {:ok, answer_binding(id, persisted)}
    else
      _ -> {:error, :answer_identity_conflict}
    end
  end

  defp answer_binding(id, persisted),
    do: %{assistant_message_id: id, public_answer_message_id: persisted}

  @doc "Prepares a provisional private root; this does not record execution authorization."
  def admit(%{person_id: id}, input, token, {:ok, _provider, _account_key})
      when is_integer(id) and id > 0 and is_binary(token) do
    %ExecutionRecord{}
    |> ExecutionRecord.changeset(%{
      person_id: id,
      user_message_id: input.id,
      finalization_token_hash: input.metadata["finalization_token_hash"]
    })
    |> Repo.insert()
  end

  def admit(_conversation, _input, _token, _source), do: {:ok, nil}

  @doc "Records successful authorization once while the caller holds the admitted-input lock."
  def accept_admission(input, execution_id) do
    case fetch(input, execution_id) do
      {:ok, nil} ->
        :ok

      {:ok, %ExecutionRecord{status: "pending", root_execution_id: nil} = execution} ->
        if execution.admitted_at do
          :ok
        else
          execution
          |> Ecto.Changeset.change(admitted_at: DateTime.utc_now())
          |> Repo.update!()

          :ok
        end

      {:ok, _} ->
        {:error, :terminal_request}

      error ->
        error
    end
  end

  @doc "Closes a denied provisional root without revoking an earlier admitted execution."
  def deny_admission(input, execution_id) do
    case fetch(input, execution_id) do
      {:ok, %ExecutionRecord{status: "pending", admitted_at: nil, root_execution_id: nil}} ->
        finish(input, nil, "failed", [], %{}, %{"reason" => "admission_denied"}, execution_id)

      _ ->
        :ok
    end
  end

  @doc "Checks the literal active execution owner, including finalization replays."
  def authorize(input, actor, execution_id \\ nil) do
    case fetch(input, execution_id) do
      {:ok, nil} -> :ok
      {:ok, execution} -> authorize_owner(execution, actor)
      error -> error
    end
  end

  @doc """
  Checks execution ownership using the active Person freshly resolved by Conversations.

  Internal to the current Engine operation: the caller already validated the actor
  and conversation owner. This snapshot is not an admission capability and must not
  be retained for later requests. Nil only supports inputs without a private record.
  """
  def authorize_resolved_person(input, person, execution_id) do
    case fetch(input, execution_id) do
      {:ok, nil} -> :ok
      {:ok, execution} -> matching_active_owner(execution, person)
      error -> error
    end
  end

  @doc "Authorizes a public-answer root, never a private steering receipt."
  def authorize_finalization(input, actor, execution_id \\ nil) do
    case fetch(input, execution_id) do
      {:ok, nil} ->
        :ok

      {:ok, execution} ->
        with :ok <- authorize_owner(execution, actor) do
          public_root(execution)
        end

      error ->
        error
    end
  end

  defp public_root(%ExecutionRecord{root_execution_id: nil}), do: :ok
  defp public_root(_execution), do: {:error, :input_not_root}

  defp authorize_owner(execution, actor) do
    with {:ok, %{person: %{id: id}}} <- ExecutionActor.validate(actor),
         %Person{} = person <- Repo.get(Person, id) do
      matching_active_owner(execution, person)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp matching_active_owner(%{person_id: id}, %Person{id: id, status: "active"}), do: :ok
  defp matching_active_owner(_execution, _person), do: {:error, :unauthorized}

  @doc "Returns whether the locked input belongs to the new private storage contract."
  def private?(input),
    do: Repo.exists?(from e in ExecutionRecord, where: e.user_message_id == ^input.id)

  @doc "Links one pending admitted input to a live root without transferring answer ownership."
  def queue(root_input, child_input, opts \\ []) do
    with {:ok, root} <- fetch(root_input, opts[:root_execution_id]),
         {:ok, child} <- fetch(child_input, opts[:execution_id]) do
      queue_records(root, child, child_input.id)
    end
  end

  defp queue_records(
         %ExecutionRecord{id: id, status: status},
         %ExecutionRecord{root_execution_id: id, status: "unconsumed"} = child,
         _input_id
       )
       when status in ["completed", "failed"],
       do: {:closed_before_accept, input_receipt(child)}

  defp queue_records(
         %ExecutionRecord{status: status, id: id},
         %ExecutionRecord{status: "consumed", root_execution_id: id},
         _input_id
       )
       when status in ["completed", "failed"], do: {:error, :terminal_request}

  defp queue_records(_root, %ExecutionRecord{status: "consumed"}, _input_id),
    do: {:error, :input_consumed}

  defp queue_records(root, child, input_id) do
    with %ExecutionRecord{root_execution_id: nil} <- root,
         %ExecutionRecord{status: "pending", root_execution_id: nil, person_id: person_id} <-
           child,
         true <- person_id == root.person_id do
      link_input(root, child, input_id)
    else
      {:error, _} = error -> error
      _ -> {:error, :input_conflict}
    end
  end

  defp link_input(root, child, _input_id) do
    {status, outcome} =
      if root.status == "pending",
        do: {"queued", child.outcome},
        else: {"unconsumed", Map.put(child.outcome, "reason", "terminal_request")}

    with {:ok, child} <-
           child
           |> ExecutionRecord.changeset(%{
             root_execution_id: root.id,
             status: status,
             outcome: outcome
           })
           |> Repo.update() do
      if status == "queued" do
        {:ok, input_receipt(child)}
      else
        {:closed_before_accept, input_receipt(child)}
      end
    end
  end

  defp input_receipt(child) do
    %{
      execution_id: child.id,
      root_execution_id: child.root_execution_id,
      refs: %{
        message_id: child.user_message_id,
        execution_id: child.id,
        root_execution_id: child.root_execution_id
      }
    }
  end

  @doc "Marks only this root's queued receipt as consumed, idempotently."
  def consume(root_input, child_input, opts \\ []) do
    with {:ok, root} <- fetch(root_input, opts[:root_execution_id]),
         {:ok, child} <- fetch(child_input, opts[:execution_id]),
         :ok <- pending_root(root),
         %ExecutionRecord{root_execution_id: root_id, status: status} <- child,
         true <- root_id == root.id and status in ["queued", "consumed"] do
      case child |> ExecutionRecord.changeset(%{status: "consumed"}) |> Repo.update() do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :input_conflict}
    end
  end

  defp pending_root(%ExecutionRecord{root_execution_id: nil, status: "pending"}), do: :ok
  defp pending_root(%ExecutionRecord{}), do: {:error, :terminal_request}
  defp pending_root(_), do: {:error, :unauthorized}

  @doc "Seals a rejected queued child, preserving consumption and terminal receipt evidence."
  def reject(root_input, child_input, reason, opts \\ []) do
    with {:ok, root} <- fetch(root_input, opts[:root_execution_id]),
         {:ok, child} <- fetch(child_input, opts[:execution_id]),
         %ExecutionRecord{root_execution_id: nil, id: root_id} <- root,
         %ExecutionRecord{root_execution_id: ^root_id} <- child do
      reject_child(child, reason)
    else
      _ -> {:error, :input_conflict}
    end
  end

  defp reject_child(%ExecutionRecord{status: "consumed"}, _reason), do: {:error, :input_consumed}
  defp reject_child(%ExecutionRecord{status: "unconsumed"}, _reason), do: :ok

  defp reject_child(%ExecutionRecord{status: "queued"} = child, reason) do
    safe_reason =
      if reason in [:stale_runtime, :terminal_request, :scope_conflict, :closed_before_accept],
        do: Atom.to_string(reason),
        else: "runtime_rejected"

    case child
         |> ExecutionRecord.changeset(%{
           status: "unconsumed",
           outcome: Map.put(child.outcome, "reason", safe_reason)
         })
         |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reject_child(_child, _reason), do: {:error, :input_conflict}

  @doc "Stores one terminal root disposition; public-answer uniqueness remains schema-enforced."
  def finish(input, answer_id, status, trace, usage, outcome, execution_id \\ nil) do
    case fetch(input, execution_id) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, execution} ->
        from(child in ExecutionRecord,
          where: child.root_execution_id == ^execution.id and child.status == "queued"
        )
        |> Repo.update_all(set: [status: "unconsumed", updated_at: DateTime.utc_now()])

        execution
        |> ExecutionRecord.changeset(%{
          status: status,
          public_answer_message_id: answer_id,
          trace_entries: trace,
          tool_results: Enum.filter(trace, &(&1["type"] == "tool_call")),
          usage: usage,
          outcome: outcome
        })
        |> Repo.update()

      error ->
        error
    end
  end

  @doc "Creates one new root linked to an unchanged rejected receipt; duplicate callers receive no capability."
  @spec prepare_followup(Message.t(), map(), map()) ::
          {:ok, map() | :already_prepared} | {:error, term()}
  def prepare_followup(input, request, actor) do
    with {:ok, %ExecutionRecord{} = receipt} <- fetch(input, request.receipt_execution_id),
         :ok <- admitted_receipt(receipt),
         :ok <- authorize_owner(receipt, actor),
         :ok <- recoverable_receipt(receipt, request.root_execution_id),
         %ExecutionRecord{status: "completed", root_execution_id: nil} <-
           Repo.get(ExecutionRecord, receipt.root_execution_id) do
      insert_followup(input, receipt)
    else
      {:error, _} = error -> error
      _ -> {:error, :prior_execution_not_completed}
    end
  end

  defp admitted_receipt(%ExecutionRecord{admitted_at: %DateTime{}}), do: :ok
  defp admitted_receipt(_), do: {:error, :admission_required}

  defp recoverable_receipt(%ExecutionRecord{status: "consumed"}, _), do: {:error, :input_consumed}

  defp recoverable_receipt(%ExecutionRecord{status: "unconsumed", root_execution_id: root}, root)
       when not is_nil(root), do: :ok

  defp recoverable_receipt(_, _), do: {:error, :input_conflict}

  defp insert_followup(input, receipt) do
    case Repo.get_by(ExecutionRecord, recovered_from_execution_id: receipt.id) do
      nil ->
        token = Ecto.UUID.generate()

        attrs = %{
          person_id: receipt.person_id,
          user_message_id: input.id,
          recovered_from_execution_id: receipt.id,
          finalization_token_hash: token |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()
        }

        with {:ok, execution} <-
               %ExecutionRecord{}
               |> ExecutionRecord.changeset(attrs)
               |> Ecto.Changeset.put_change(:admitted_at, receipt.admitted_at)
               |> Repo.insert() do
          {:ok,
           %{
             conversation_id: input.conversation_id,
             user_message_id: input.id,
             execution_id: execution.id,
             finalization_token: token
           }}
        end

      _ ->
        {:ok, :already_prepared}
    end
  end
end
