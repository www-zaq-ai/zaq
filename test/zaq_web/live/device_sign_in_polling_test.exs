defmodule ZaqWeb.Live.DeviceSignInPollingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ZaqWeb.Live.DeviceSignInPolling

  test "shared observer admits one request and one completion, keeping authority private" do
    dispatch = fn command -> send(self(), {:command, command}) end

    complete = fn socket, receipt ->
      send(self(), {:complete, receipt})
      socket
    end

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    socket =
      DeviceSignInPolling.open(socket, nil,
        view_key: :view,
        dispatch: dispatch,
        on_complete: complete
      )

    socket = DeviceSignInPolling.request(socket, {:begin, %{}})
    state = socket.private.sign_in_observer
    assert DeviceSignInPolling.request(socket, {:begin, %{}}) == socket

    {:ok, view} =
      Zaq.SignIn.view(:opaque, %{
        status: "active",
        completion: %{id: 4, kind: :credential},
        observe: false
      })

    result = {:ok, {dispatch, {:ok, view}}}
    socket = DeviceSignInPolling.result(socket, state.generation, state.in_flight, result)
    assert_receive {:complete, %{id: 4}}
    refute Map.has_key?(socket.assigns.view, :ref)
    refute Map.has_key?(socket.assigns.view, :dispatch)
    assert DeviceSignInPolling.result(socket, state.generation, state.in_flight, result) == socket
    refute_receive {:complete, _}
  end

  test "shared observation replaces challenges, clears missing attempts, and rejects stale ticks" do
    dispatch = fn _ -> :unused end
    {:ok, view} = Zaq.SignIn.view(:opaque, %{challenge: %{type: :qr, value: "first"}})
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    socket = DeviceSignInPolling.open(socket, view, view_key: :view, dispatch: dispatch)
    timer = socket.private.sign_in_observer_timer
    socket = DeviceSignInPolling.tick(socket, timer.identity, timer.generation)
    state = socket.private.sign_in_observer
    assert DeviceSignInPolling.tick(socket, timer.identity, timer.generation) == socket
    {:ok, rotated} = Zaq.SignIn.view(:opaque, %{challenge: %{type: :qr, value: "second"}})

    socket =
      DeviceSignInPolling.result(
        socket,
        state.generation,
        state.in_flight,
        {:ok, {dispatch, {:ok, rotated}}}
      )

    assert socket.assigns.view.challenge.value == "second"
    assert socket.private.sign_in_observer.generation == state.generation
    socket = DeviceSignInPolling.request(socket, {:observe, :opaque})
    state = socket.private.sign_in_observer

    socket =
      DeviceSignInPolling.result(
        socket,
        state.generation,
        state.in_flight,
        {:ok, {dispatch, {:ok, nil}}}
      )

    assert socket.assigns.view == nil
    assert socket.private.sign_in_observer_timer == nil
  end

  test "dismissal follows normalized policy and never cancels the current ref for stale results" do
    owner = self()

    dispatch = fn command ->
      send(owner, {:command, command})
      {:ok, nil}
    end

    {:ok, view} = Zaq.SignIn.view(:current, %{dismiss: :cancel})
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    socket = DeviceSignInPolling.open(socket, view, view_key: :view, dispatch: dispatch)
    {:ok, stale} = Zaq.SignIn.view(:current, %{dismiss: :cancel})

    assert DeviceSignInPolling.result(
             socket,
             make_ref(),
             make_ref(),
             {:ok, {dispatch, {:ok, stale}}}
           ) == socket

    refute_receive {:command, _}
    socket = DeviceSignInPolling.dismiss(socket)
    assert socket.assigns.view == nil
    assert_receive {:command, {:cancel, :current}}
    assert socket.private.sign_in_observer == nil
  end

  property "duplicate and stale completion deliveries never repeat the admitted callback" do
    check all(deliveries <- list_of(member_of([:current, :stale]), min_length: 1, max_length: 30)) do
      owner = self()
      dispatch = fn _ -> :unused end
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      socket =
        DeviceSignInPolling.open(socket, nil,
          view_key: :view,
          dispatch: dispatch,
          on_complete: fn socket, _ ->
            send(owner, :completed)
            socket
          end
        )

      socket = DeviceSignInPolling.request(socket, {:begin, %{}})
      state = socket.private.sign_in_observer

      {:ok, view} =
        Zaq.SignIn.view(:opaque, %{status: "active", completion: %{id: 1}, observe: false})

      result = {:ok, {dispatch, {:ok, view}}}

      socket =
        Enum.reduce(deliveries, socket, fn delivery, socket ->
          generation = if delivery == :current, do: state.generation, else: make_ref()
          DeviceSignInPolling.result(socket, generation, state.in_flight, result)
        end)

      if :current in deliveries, do: assert_receive(:completed)
      refute_receive :completed, 0
      DeviceSignInPolling.dismiss(socket)
    end
  end

  test "malformed observations clear instructions and projection allowlists exclude authority" do
    dispatch = fn _ -> :unused end
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {:ok, view} =
      Zaq.SignIn.view(:opaque, %{
        challenge: %{type: :qr, value: "safe", token: "SECRET"},
        confirmation: %{external_id: "account", owner_id: "SECRET"}
      })

    socket = DeviceSignInPolling.open(socket, view, view_key: :view, dispatch: dispatch)
    refute inspect(socket.assigns) =~ "SECRET"
    socket = DeviceSignInPolling.request(socket, :observe)
    state = socket.private.sign_in_observer

    socket =
      DeviceSignInPolling.result(
        socket,
        state.generation,
        state.in_flight,
        {:ok, {dispatch, {:ok, %{status: :not_a_status, challenge: "SECRET"}}}}
      )

    assert socket.assigns.view.status == "unavailable"
    assert socket.assigns.view.challenge == nil
    assert socket.private.sign_in_observer_timer == nil
    DeviceSignInPolling.dismiss(socket)
  end

  test "cancel during initiation waits for its ref without overlapping commands" do
    dispatch = fn _ -> :unused end
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    socket = DeviceSignInPolling.open(socket, nil, view_key: :view, dispatch: dispatch)
    socket = DeviceSignInPolling.request(socket, {:begin, %{}})
    first = socket.private.sign_in_observer
    socket = DeviceSignInPolling.request(socket, :cancel)
    assert socket.private.sign_in_observer.in_flight == first.in_flight
    assert socket.private.sign_in_observer.cancel_requested
    {:ok, view} = Zaq.SignIn.view(:new_ref, %{})

    socket =
      DeviceSignInPolling.result(
        socket,
        first.generation,
        first.in_flight,
        {:ok, {dispatch, {:ok, view}}}
      )

    next = socket.private.sign_in_observer
    refute next.in_flight == first.in_flight
    refute next.cancel_requested
    assert next.ref == :new_ref
    assert socket.private.sign_in_observer_timer == nil
    DeviceSignInPolling.dismiss(socket)
  end

  test "timer ownership stays private and dismissal cancels observation" do
    socket = open_observation(socket(), "first")
    timer = socket.private.sign_in_observer_timer
    refute Map.has_key?(socket.assigns, :sign_in_observer_timer)
    stopped = DeviceSignInPolling.dismiss(socket)
    assert stopped.private.sign_in_observer_timer == nil
    assert Process.read_timer(timer.timer_ref) == false
    assert DeviceSignInPolling.tick(stopped, timer.identity, timer.generation) == stopped
    assert DeviceSignInPolling.dismiss(stopped) == stopped
    refute Map.has_key?(stopped.assigns, :sign_in_observer_timer)
  end

  test "reopening an observed attempt keeps one timer; switching cancels and invalidates it" do
    socket = open_observation(socket(), "first")
    first = socket.private.sign_in_observer_timer
    on_exit(fn -> Process.cancel_timer(first.timer_ref) end)

    reopened = open_observation(socket, "first")
    assert reopened.private.sign_in_observer_timer == first
    switched = open_observation(reopened, "second")
    second = switched.private.sign_in_observer_timer
    on_exit(fn -> Process.cancel_timer(second.timer_ref) end)
    assert Process.read_timer(first.timer_ref) == false
    assert DeviceSignInPolling.tick(switched, first.identity, first.generation) == switched
    assert DeviceSignInPolling.tick(switched, second.identity, first.generation) == switched
    DeviceSignInPolling.dismiss(switched)
  end

  test "consumption allows one successor and rejects duplicate delivered messages" do
    socket = open_observation(socket(), "first")
    first = socket.private.sign_in_observer_timer
    consumed = DeviceSignInPolling.tick(socket, first.identity, first.generation)
    assert consumed.private.sign_in_observer_timer == nil
    assert Process.read_timer(first.timer_ref) == false
    assert DeviceSignInPolling.tick(consumed, first.identity, first.generation) == consumed
    state = consumed.private.sign_in_observer

    next =
      DeviceSignInPolling.result(
        consumed,
        state.generation,
        state.in_flight,
        {:ok, {state.dispatch, {:ok, state.view}}}
      )

    second = next.private.sign_in_observer_timer
    on_exit(fn -> Process.cancel_timer(second.timer_ref) end)
    refute second.generation == first.generation
    assert DeviceSignInPolling.tick(next, first.identity, first.generation) == next

    {:ok, active} = Zaq.SignIn.view("first", %{status: "active", observe: false})
    stopped = DeviceSignInPolling.open(next, active, view_key: :view, dispatch: state.dispatch)

    assert stopped.private.sign_in_observer_timer == nil
    assert Process.read_timer(second.timer_ref) == false
    DeviceSignInPolling.dismiss(stopped)
  end

  property "arbitrary reopen and switching sequences leave at most one live timer" do
    check all(ids <- list_of(member_of(["a", "b", "c"]), min_length: 1, max_length: 20)) do
      {socket, refs} =
        Enum.reduce(ids, {socket(), []}, fn id, {socket, refs} ->
          next = open_observation(socket, id)
          {next, Enum.uniq([next.private.sign_in_observer_timer.timer_ref | refs])}
        end)

      assert Enum.count(refs, &(Process.read_timer(&1) != false)) == 1
      DeviceSignInPolling.dismiss(socket)
      assert Enum.all?(refs, &(Process.read_timer(&1) == false))
    end
  end

  test "changing the observation interval replaces and invalidates the old timer" do
    socket = open_observation(socket(), "first", 2_000)
    first = socket.private.sign_in_observer_timer
    assert first.interval_ms == 2_000
    reopened = open_observation(socket, "first", 1_000)
    second = reopened.private.sign_in_observer_timer
    assert Process.read_timer(first.timer_ref) == false
    assert second.interval_ms == 1_000
    assert DeviceSignInPolling.tick(reopened, first.identity, first.generation) == reopened
    DeviceSignInPolling.dismiss(reopened)
  end

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  defp open_observation(socket, id, interval \\ 60_000) do
    {:ok, view} = Zaq.SignIn.view(id, %{interval_ms: interval})
    DeviceSignInPolling.open(socket, view, view_key: :view, dispatch: fn _ -> :unused end)
  end
end
