defmodule Zaq.Engine.Extension.ActionSessionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.{ActionProtocol, ActionSession}
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{ActionRequest, ListActions, ZaqEnvelope}

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
