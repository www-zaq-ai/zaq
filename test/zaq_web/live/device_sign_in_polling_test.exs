defmodule ZaqWeb.Live.DeviceSignInPollingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ZaqWeb.Live.DeviceSignInPolling

  test "reopening an observed attempt keeps one timer; switching cancels and invalidates it" do
    socket = %Phoenix.LiveView.Socket{}
    attempt = %{attempt_id: "first", status: "pending"}
    socket = DeviceSignInPolling.schedule(socket, attempt, :device_status)
    first = socket.private.device_sign_in_polling
    on_exit(fn -> Process.cancel_timer(first.timer_ref) end)

    reopened = DeviceSignInPolling.schedule(socket, attempt, :device_status)
    assert reopened.private.device_sign_in_polling == first

    switched =
      DeviceSignInPolling.schedule(
        reopened,
        %{attempt_id: "second", status: "initializing"},
        :device_status
      )

    second = switched.private.device_sign_in_polling
    on_exit(fn -> Process.cancel_timer(second.timer_ref) end)
    assert Process.read_timer(first.timer_ref) == false
    assert :stale = DeviceSignInPolling.consume(switched, "first", first.generation)
    assert :stale = DeviceSignInPolling.consume(switched, "second", first.generation)
  end

  test "consumption allows one successor and rejects duplicate delivered messages" do
    attempt = %{attempt_id: "first", status: "pending"}
    socket = DeviceSignInPolling.schedule(%Phoenix.LiveView.Socket{}, attempt, :device_status)
    first = socket.private.device_sign_in_polling
    assert {:ok, consumed} = DeviceSignInPolling.consume(socket, "first", first.generation)
    assert :stale = DeviceSignInPolling.consume(consumed, "first", first.generation)
    next = DeviceSignInPolling.schedule(consumed, attempt, :device_status)
    second = next.private.device_sign_in_polling
    on_exit(fn -> Process.cancel_timer(second.timer_ref) end)
    refute second.generation == first.generation
    assert :stale = DeviceSignInPolling.consume(next, "first", first.generation)

    stopped =
      DeviceSignInPolling.schedule(next, %{attempt_id: "first", status: "active"}, :device_status)

    assert stopped.private.device_sign_in_polling == nil
    assert Process.read_timer(second.timer_ref) == false
  end

  property "arbitrary reopen and switching sequences leave at most one live timer" do
    check all(ids <- list_of(member_of(["a", "b", "c"]), min_length: 1, max_length: 20)) do
      {socket, refs} =
        Enum.reduce(ids, {%Phoenix.LiveView.Socket{}, []}, fn id, {socket, refs} ->
          next =
            DeviceSignInPolling.schedule(
              socket,
              %{attempt_id: id, status: "pending"},
              :device_status
            )

          {next, Enum.uniq([next.private.device_sign_in_polling.timer_ref | refs])}
        end)

      assert Enum.count(refs, &(Process.read_timer(&1) != false)) == 1
      DeviceSignInPolling.schedule(socket, nil, :device_status)
      assert Enum.all?(refs, &(Process.read_timer(&1) == false))
    end
  end
end
