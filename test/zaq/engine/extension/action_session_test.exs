defmodule Zaq.Engine.Extension.ActionSessionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.{ActionProtocol, ActionSession}

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionReply,
    ActionRequest,
    ExecuteAction,
    ListActions,
    ZaqEnvelope
  }

  test "unsupported operations leave an isolated session unchanged" do
    supervisor = start_supervised!({Task.Supervisor, []})
    id = Ecto.UUID.generate()
    limits = ActionProtocol.offer(262_144)
    base = ActionSession.new(supervisor)

    execute = %ExecuteAction{
      key: "arithmetic.add",
      arguments_json: ~s({"value":2.0,"amount":3.0}),
      mode: :SYNC
    }

    valid_request = %ActionRequest{timeout_ms: 1_000, operation: {:execute, execute}}

    assert {:error, :unsupported_operation, ^base} =
             ActionSession.request(base, id, valid_request)

    assert {nil, ^base} = ActionSession.take_next(base)
    assert Task.Supervisor.children(supervisor) == []
    refute_receive {:extension_action_completed, _, ^id, _}

    session = ActionSession.configure(base, limits, make_ref())

    for operation <- [nil, {:future, %{}}] do
      request = %ActionRequest{timeout_ms: 1_000, operation: operation}

      assert {:error, :unsupported_operation, ^session} =
               ActionSession.request(session, id, request)

      assert {nil, ^session} = ActionSession.take_next(session)
      assert Task.Supervisor.children(supervisor) == []
    end
  end

  test "failed SYNC and ASYNC admission report UNAVAILABLE and release all reservations" do
    for mode <- [:SYNC, :ASYNC] do
      supervisor = start_supervised!({Task.Supervisor, [max_children: 1]}, id: make_ref())
      parent = self()

      blocker =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:admission_blocked, self()})
          receive do: (:release -> :ok)
        end)

      assert_receive {:admission_blocked, blocker_pid}
      blocker_monitor = Process.monitor(blocker_pid)
      on_exit(fn -> if Process.alive?(blocker_pid), do: send(blocker_pid, :release) end)
      limits = %{ActionProtocol.offer(262_144) | max_concurrent: 2}
      generation = make_ref()
      session = ActionSession.configure(ActionSession.new(supervisor), limits, generation)
      id = Ecto.UUID.generate()

      request = %ActionRequest{
        timeout_ms: 5_000,
        operation:
          {:execute,
           %ExecuteAction{
             key: "arithmetic.add",
             arguments_json: ~s({"value":2.0,"amount":3.0}),
             mode: mode
           }}
      }

      assert {:ok, session} = ActionSession.request(session, id, request)
      assert ActionSession.worker_down(session, make_ref()) == session
      assert session.workers == %{}
      assert {{1, frame}, session} = ActionSession.take_next(session)
      assert frame.request_id == id

      assert {:action_reply, %ActionReply{sequence: 1, outcome: {:failure, failure}}} =
               frame.payload

      assert failure.code == :UNAVAILABLE
      assert failure.effects_may_have_occurred == false
      assert session.used_slots == 1
      assert session.used_bytes == byte_size(ZaqEnvelope.encode(frame))
      assert {nil, ^session} = ActionSession.take_next(session)
      refute_receive {:extension_action_completed, ^generation, ^id, _}
      assert {:ok, session} = ActionSession.receipt(session, id, 1)
      assert session.used_slots == 0
      assert session.used_bytes == 0
      assert session.requests == %{}
      assert session.replies == %{}
      assert {:error, :invalid_envelope, ^session} = ActionSession.receipt(session, id, 1)
      assert {nil, ^session} = ActionSession.take_next(session)
      assert Enum.sort(Task.Supervisor.children(supervisor)) == [blocker_pid]
      send(blocker_pid, :release)
      assert Task.yield(blocker, 1_000) == {:ok, :ok}
      assert_receive {:DOWN, ^blocker_monitor, :process, ^blocker_pid, :normal}
    end
  end

  test "worker completions cannot enqueue duplicate pending Health probes after a blocked write" do
    generation = make_ref()

    state = %{
      phase: :ready,
      writer: %{pid: self()},
      generation: generation,
      writing: true,
      pending: nil,
      probe_due: false,
      scheduled: nil,
      deadline: nil,
      probe_timeout_ms: 5_000,
      actions: %ActionSession{}
    }

    {:noreply, state} = Extension.handle_info(:probe, state)
    {:noreply, state} = Extension.handle_info({:extension_sent, generation}, state)
    assert_receive :probe

    {:noreply, state} =
      Extension.handle_info(
        {:extension_action_completed, make_ref(), Ecto.UUID.generate(), nil},
        state
      )

    refute_receive :probe
    Process.cancel_timer(elem(state.deadline, 0))
  end

  property "every invalid-operation reply reserves and releases its exact encoded envelope bytes" do
    check all(timeout <- integer(60_001..100_000), max_runs: 30) do
      limits = ActionProtocol.offer(262_144)
      generation = make_ref()
      session = ActionSession.configure(%ActionSession{}, limits, generation)
      id = Ecto.UUID.generate()
      request = %ActionRequest{timeout_ms: timeout, operation: {:list, %ListActions{}}}
      assert {:ok, session} = ActionSession.request(session, id, request)
      assert session.used_slots == 1
      assert {{1, frame}, session} = ActionSession.take_next(session)
      assert session.used_bytes == byte_size(ZaqEnvelope.encode(frame))
      assert {:ok, session} = ActionSession.receipt(session, id, 1)
      assert session.used_slots == 0
      assert session.used_bytes == 0
      assert session.requests == %{}
      assert {:error, :invalid_envelope, ^session} = ActionSession.receipt(session, id, 1)
    end
  end

  test "a 372-byte base64 result fits JSON but its encoded envelope exceeds the reservation" do
    supervisor = start_supervised!({Task.Supervisor, []})
    assert_base64_result_falls_back(supervisor, 372)
  end

  property "base64 JSON results fitting 512 bytes fall back when the protobuf envelope does not" do
    supervisor = start_supervised!({Task.Supervisor, []})

    check all(length <- integer(348..372), max_runs: 25) do
      assert_base64_result_falls_back(supervisor, length)
    end
  end

  defp assert_base64_result_falls_back(supervisor, length) do
    limits = %{ActionProtocol.offer(262_144) | max_reply_envelope_bytes: 512}
    generation = make_ref()
    session = ActionSession.configure(ActionSession.new(supervisor), limits, generation)
    id = Ecto.UUID.generate()

    request = %ActionRequest{
      timeout_ms: 5_000,
      operation:
        {:execute,
         %ExecuteAction{
           key: "general.encode_base64",
           arguments_json: Jason.encode!(%{"data" => String.duplicate("x", length)}),
           mode: :SYNC
         }}
    }

    assert {:ok, session} = ActionSession.request(session, id, request)
    [{ref, %{id: ^id, pid: worker_pid}}] = Map.to_list(session.workers)
    assert_receive {:extension_action_completed, ^generation, ^id, {:result_json, json}}, 5_000
    assert byte_size(json) <= 512
    assert Jason.decode!(json) == %{"encoded" => Base.encode64(String.duplicate("x", length))}

    success = %ZaqEnvelope{
      request_id: id,
      protocol_version: 1,
      payload: {:action_reply, %ActionReply{sequence: 1, outcome: {:result_json, json}}}
    }

    assert byte_size(ZaqEnvelope.encode(success)) > 512

    session = ActionSession.complete(session, generation, id, {:result_json, json})
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 5_000
    session = ActionSession.worker_down(session, ref)
    assert session.workers == %{}
    assert {{1, frame}, session} = ActionSession.take_next(session)
    assert frame.request_id == id

    assert {:action_reply,
            %ActionReply{
              sequence: 1,
              outcome: {:failure, %{code: :RESULT_TOO_LARGE, effects_may_have_occurred: true}}
            }} = frame.payload

    assert byte_size(ZaqEnvelope.encode(frame)) <= 512
    assert session.used_bytes == byte_size(ZaqEnvelope.encode(frame))
    assert {:ok, session} = ActionSession.receipt(session, id, 1)
    assert session.used_slots == 0
    assert session.used_bytes == 0
    assert session.requests == %{}
    assert session.replies == %{}
  end

  test "a known rejection requires a slot and at least 512 available bytes before enqueueing" do
    limits = ActionProtocol.offer(262_144)
    session = ActionSession.configure(%ActionSession{}, limits, make_ref())

    request = %ActionRequest{
      timeout_ms: limits.max_timeout_ms + 1,
      operation: {:list, %ListActions{}}
    }

    id = Ecto.UUID.generate()

    short = %{session | used_bytes: limits.max_unreceipted_bytes - 511}
    assert {:error, :resource_exhausted, ^short} = ActionSession.request(short, id, request)

    fits = %{short | used_bytes: short.used_bytes - 1}
    assert {:ok, session} = ActionSession.request(fits, id, request)
    assert {{1, _frame}, session} = ActionSession.take_next(session)
    assert {:ok, session} = ActionSession.receipt(session, id, 1)
    assert session.used_bytes == fits.used_bytes
    assert session.used_slots == fits.used_slots
  end

  test "a lost worker completion settles once with a safe failure instead of leaking its slot" do
    generation = make_ref()
    id = Ecto.UUID.generate()
    ref = make_ref()
    limits = ActionProtocol.offer(262_144)

    session = %ActionSession{
      limits: limits,
      generation: generation,
      requests: %{
        id => %{
          waiting: true,
          timer: nil,
          expires_at: System.monotonic_time(:millisecond) + 5_000
        }
      },
      workers: %{ref => %{id: id, generation: generation, pid: self()}},
      used_slots: 1,
      used_bytes: limits.max_reply_envelope_bytes
    }

    session = ActionSession.worker_down(session, ref)
    assert session.workers == %{}

    assert {{1, %{payload: {:action_reply, %{outcome: {:failure, failure}}}}}, session} =
             ActionSession.take_next(session)

    assert failure.code == :INTERNAL
    assert failure.effects_may_have_occurred
    assert ^session = ActionSession.complete(session, generation, id, {:result_json, "{}"})
    assert {:ok, session} = ActionSession.receipt(session, id, 1)
    assert session.used_slots == 0
    assert session.requests == %{}
  end
end
