defmodule Zaq.Engine.Extension.ActionSession do
  @moduledoc """
  Transient Action admission, worker accounting and reply-credit ledger.
  Disconnect discards transport state, but never releases a still-running worker's
  concurrency slot. Receipts acknowledge encoded envelopes, not business success.
  """

  alias Zaq.Engine.Extension.{ActionProtocol, Actions}
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{ActionReply, Relayed, ZaqEnvelope}
  alias Zaq.{Event, NodeRouter}

  defstruct limits: nil,
            generation: nil,
            requests: %{},
            workers: %{},
            replies: %{},
            sequence: 0,
            used_slots: 0,
            used_bytes: 0

  @type t :: %__MODULE__{}

  @doc "Starts a fresh transport generation while retaining live worker monitors."
  @spec configure(t(), term(), reference() | nil) :: t()
  def configure(session, limits, generation) do
    Enum.each(session.requests, fn {_id, request} -> cancel(request.timer) end)
    Enum.each(session.replies, fn {_seq, reply} -> cancel(reply.timer) end)
    %__MODULE__{limits: limits, generation: generation, workers: session.workers}
  end

  @doc "Reserves terminal/ACK capacity before starting the existing asynchronous Engine hop."
  @spec request(t(), String.t(), struct()) :: {:ok, t()} | {:error, atom(), t()}
  def request(%{limits: nil} = session, _id, _request),
    do: {:error, :unsupported_operation, session}

  def request(session, id, request) do
    started_at = System.monotonic_time(:millisecond)

    cond do
      not ActionProtocol.valid_id?(id) or active?(session, id) ->
        {:error, :invalid_envelope, session}

      is_nil(request.operation) ->
        {:error, :unsupported_operation, session}

      true ->
        admit(session, id, request, started_at)
    end
  end

  defp admit(session, id, request, started_at) do
    case ActionProtocol.invocation(request, session.limits) do
      {:ok, invocation, mode} ->
        admit_invocation(session, id, invocation, request.timeout_ms, mode, started_at)

      {:error, :unsupported_operation} ->
        {:error, :unsupported_operation, session}

      {:error, code} ->
        reject_request(session, id, code)
    end
  end

  defp admit_invocation(session, id, invocation, timeout, mode, started_at) do
    if map_size(session.workers) < session.limits.max_concurrent do
      with {:ok, session} <- reserve(session, id, mode),
           do: {:ok, dispatch(session, id, invocation, timeout, mode, started_at)}
    else
      reject_request(session, id, :RESOURCE_EXHAUSTED)
    end
  end

  defp reject_request(session, id, code) do
    with {:ok, session} <- reserve(session, id, :SYNC),
         do: {:ok, finish(session, id, Actions.failure(code))}
  end

  defp reserve(session, id, mode) do
    slots = if mode == :ASYNC, do: 2, else: 1
    bytes = session.limits.max_reply_envelope_bytes + if(mode == :ASYNC, do: 512, else: 0)

    if session.used_slots + slots <= session.limits.max_unreceipted_replies and
         session.used_bytes + bytes <= session.limits.max_unreceipted_bytes do
      entry = %{waiting: true, timer: nil, expires_at: nil}

      {:ok,
       %{
         session
         | requests: Map.put(session.requests, id, entry),
           used_slots: session.used_slots + slots,
           used_bytes: session.used_bytes + bytes
       }}
    else
      {:error, :resource_exhausted, session}
    end
  end

  defp dispatch(session, id, invocation, timeout_ms, mode, started_at) do
    event =
      Event.new(invocation, :engine,
        type: :async,
        trace_id: id,
        opts: [action: :extension_action, confidential: true, track_dispatch: true],
        assigns: %{extension_owner: self(), extension_generation: session.generation}
      )

    case NodeRouter.dispatch(event) do
      %Event{assigns: %{async_task_pid: pid}} when is_pid(pid) ->
        ref = Process.monitor(pid)
        remaining = max(timeout_ms - (System.monotonic_time(:millisecond) - started_at), 0)
        timer = Process.send_after(self(), {:action_deadline, session.generation, id}, remaining)
        entry = %{session.requests[id] | timer: timer, expires_at: started_at + timeout_ms}
        worker = %{id: id, generation: session.generation, pid: pid}

        session = %{
          session
          | requests: Map.put(session.requests, id, entry),
            workers: Map.put(session.workers, ref, worker)
        }

        if mode == :ASYNC, do: enqueue(session, id, {:relayed, %Relayed{}}, 512), else: session

      _ ->
        session =
          if mode == :ASYNC,
            do: %{
              session
              | used_slots: session.used_slots - 1,
                used_bytes: session.used_bytes - 512
            },
            else: session

        finish(session, id, Actions.failure(:UNAVAILABLE))
    end
  end

  @doc "Settles a waiting invocation once; late or old-generation completions are ignored."
  @spec complete(t(), reference(), String.t(), term()) :: t()
  def complete(%{generation: generation} = session, generation, id, outcome) do
    case session.requests[id] do
      %{waiting: true, expires_at: expires_at} ->
        outcome =
          if expires_at && System.monotonic_time(:millisecond) >= expires_at,
            do: Actions.failure(:DEADLINE_EXCEEDED, true),
            else: outcome

        finish(session, id, outcome)

      _ ->
        session
    end
  end

  def complete(session, _generation, _id, _outcome), do: session

  @doc "Stops waiting without cancelling execution or freeing its worker capacity."
  @spec deadline(t(), reference(), String.t()) :: t()
  def deadline(session, generation, id),
    do: complete(session, generation, id, Actions.failure(:DEADLINE_EXCEEDED, true))

  @doc "Releases execution capacity only after actual worker death."
  @spec worker_down(t(), reference()) :: t()
  def worker_down(session, ref) do
    case Map.pop(session.workers, ref) do
      {nil, _} ->
        session

      {%{id: id, generation: generation}, workers} ->
        complete(%{session | workers: workers}, generation, id, Actions.failure(:INTERNAL, true))
    end
  end

  defp finish(session, id, outcome) do
    entry = session.requests[id]
    cancel(entry.timer)

    session = %{
      session
      | requests: Map.put(session.requests, id, %{entry | waiting: false, timer: nil})
    }

    enqueue(session, id, outcome, session.limits.max_reply_envelope_bytes)
  end

  defp enqueue(session, id, outcome, reservation) do
    sequence = session.sequence + 1
    frame = envelope(id, sequence, outcome)
    size = frame |> ZaqEnvelope.encode() |> byte_size()
    {frame, size} = bounded_frame(frame, size, reservation)
    reply = %{id: id, bytes: size, frame: frame, timer: nil, writing: false}

    %{
      session
      | sequence: sequence,
        replies: Map.put(session.replies, sequence, reply),
        used_bytes: session.used_bytes - reservation + size
    }
  end

  defp bounded_frame(frame, size, reservation) when size <= reservation, do: {frame, size}

  defp bounded_frame(frame, _size, _reservation) do
    replacement =
      envelope(
        frame.request_id,
        elem(frame.payload, 1).sequence,
        Actions.failure(:RESULT_TOO_LARGE, true)
      )

    {replacement, replacement |> ZaqEnvelope.encode() |> byte_size()}
  end

  defp envelope(id, sequence, outcome),
    do: %ZaqEnvelope{
      request_id: id,
      protocol_version: 1,
      payload: {:action_reply, %ActionReply{sequence: sequence, outcome: outcome}}
    }

  @doc false
  @spec take_next(t()) :: {nil | {pos_integer(), ZaqEnvelope.t()}, t()}
  def take_next(session) do
    queued =
      session.replies
      |> Enum.filter(fn {_seq, reply} -> not reply.writing end)
      |> Enum.min_by(&elem(&1, 0), fn -> nil end)

    case queued do
      nil ->
        {nil, session}

      {seq, reply} ->
        timer =
          Process.send_after(
            self(),
            {:action_receipt_deadline, session.generation, seq},
            session.limits.receipt_timeout_ms
          )

        {{seq, reply.frame},
         %{
           session
           | replies:
               Map.put(session.replies, seq, %{reply | frame: nil, timer: timer, writing: true})
         }}
    end
  end

  @doc "Releases only the exact outstanding reply's credits; malformed or duplicate receipts fail closed."
  @spec receipt(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, atom(), t()}
  def receipt(session, id, sequence) do
    case session.replies[sequence] do
      %{id: ^id, writing: true} = reply ->
        cancel(reply.timer)

        session = %{
          session
          | replies: Map.delete(session.replies, sequence),
            used_bytes: session.used_bytes - reply.bytes,
            used_slots: session.used_slots - 1
        }

        {:ok, retire_request(session, id)}

      _ ->
        {:error, :invalid_envelope, session}
    end
  end

  defp retire_request(session, id) do
    if match?(%{waiting: false}, session.requests[id]) and
         not Enum.any?(session.replies, fn {_seq, reply} -> reply.id == id end) do
      %{session | requests: Map.delete(session.requests, id)}
    else
      session
    end
  end

  defp active?(session, id),
    do:
      Map.has_key?(session.requests, id) or
        Enum.any?(session.workers, fn {_ref, worker} -> worker.id == id end)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
