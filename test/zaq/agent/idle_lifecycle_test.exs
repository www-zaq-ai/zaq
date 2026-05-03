defmodule Zaq.Agent.IdleLifecycleTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.IdleLifecycle

  test "init/2 starts idle timer when timeout is a positive integer" do
    state = %{id: "server-1", lifecycle: %{idle_timeout: 50, idle_timer: nil}}

    assert %{lifecycle: %{idle_timer: ref}} = IdleLifecycle.init([], state)
    assert is_reference(ref)
    :erlang.cancel_timer(ref)
  end

  test "init/2 keeps state unchanged when timeout is invalid" do
    state = %{id: "server-1", lifecycle: %{idle_timeout: 0, idle_timer: nil}}
    assert IdleLifecycle.init([], state) == state
  end

  test "handle_event(:touch, ...) cancels old timer and starts a new one" do
    old_ref = :erlang.start_timer(1000, self(), :lifecycle_idle_timeout)

    state = %{id: "server-1", lifecycle: %{idle_timeout: 1000, idle_timer: old_ref}}

    assert {:cont, %{lifecycle: %{idle_timer: new_ref}}} =
             IdleLifecycle.handle_event(:touch, state)

    assert is_reference(new_ref)
    refute new_ref == old_ref
    :erlang.cancel_timer(new_ref)
  end

  test "handle_event(:idle_timeout, ...) returns cont without crashing" do
    state = %{id: "server-42", lifecycle: %{idle_timeout: 1000, idle_timer: nil}}

    assert {:cont, ^state} = IdleLifecycle.handle_event(:idle_timeout, state)
  end

  test "handle_event for unknown event is a no-op" do
    state = %{id: "server-1", lifecycle: %{idle_timeout: 1000, idle_timer: nil}}
    assert {:cont, ^state} = IdleLifecycle.handle_event(:other, state)
  end
end
