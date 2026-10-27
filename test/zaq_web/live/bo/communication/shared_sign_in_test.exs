defmodule ZaqWeb.Live.BO.Communication.SharedSignInTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn
  alias ZaqWeb.Live.DeviceSignInPolling, as: Observer

  test "poll ticks are consumed once without rotating the result generation" do
    socket = socket()
    state = socket.private.sign_in_observer
    timer = socket.private.sign_in_observer_timer
    assert timer.interval_ms == 2_000
    assert Observer.tick(socket, state.generation, make_ref()) == socket
    consumed = Observer.tick(socket, state.generation, timer.generation)
    assert consumed.private.sign_in_observer_timer == nil
    assert consumed.private.sign_in_observer.generation == state.generation
    assert Observer.tick(consumed, state.generation, timer.generation) == consumed
    successor = deliver(consumed, %{status: "pending", observe: true})
    refute successor.private.sign_in_observer_timer.generation == timer.generation
    assert Observer.tick(successor, state.generation, timer.generation) == successor
    Observer.dismiss(successor)
  end

  test "stale result and timer cannot update another selected connector" do
    socket = socket()

    assert Observer.result(
             socket,
             make_ref(),
             make_ref(),
             response(%{challenge: %{type: :qr, value: "wrong"}})
           ) == socket

    assert Observer.tick(socket, make_ref(), make_ref()) == socket
    assert socket.private.sign_in_observer.ref == {:connector, 2}
    Observer.dismiss(socket)
  end

  test "closing cancels polling and clears QR material including late results" do
    socket = socket(%{challenge: %{type: :qr, value: "current"}})
    state = socket.private.sign_in_observer
    timer = socket.private.sign_in_observer_timer.timer_ref
    closed = Observer.dismiss(socket)
    assert closed.assigns.view == nil
    assert Process.read_timer(timer) == false

    assert Observer.result(
             closed,
             state.generation,
             make_ref(),
             response(%{challenge: %{type: :qr, value: "late"}})
           ) == closed
  end

  test "retry failure clears QR and observation is bounded" do
    socket = socket(%{challenge: %{type: :qr, value: "current"}})
    failed = deliver(socket, {:error, :restart_failed})
    assert failed.assigns.view.status == "unavailable"
    assert failed.assigns.view.challenge == nil
    state = %{socket.private.sign_in_observer | attempts: 89}
    socket = Phoenix.LiveView.put_private(socket, :sign_in_observer, state)
    expired = deliver(socket, %{challenge: %{type: :qr, value: "old"}})
    assert expired.assigns.view.status == "expired"
    assert expired.assigns.view.challenge == nil
    assert expired.private.sign_in_observer_timer == nil
  end

  test "provisional retry preserves the failed session and resets generation and budget" do
    socket = socket(%{ref: self(), status: "failed", retry: :resume})
    state = socket.private.sign_in_observer
    retried = Observer.request(socket, :retry)
    assert retried.private.sign_in_observer.ref == self()
    refute retried.private.sign_in_observer.generation == state.generation
    assert retried.private.sign_in_observer.attempts == 0
    assert retried.private.sign_in_observer.in_flight != nil
    Observer.dismiss(retried)
  end

  test "recovering pairing keeps polling, confirmation stops it and session expiry is terminal" do
    socket = socket(%{summary: "Reconnecting with the linked account"})
    timer = socket.private.sign_in_observer_timer.timer_ref
    confirmed = deliver(socket, %{status: "confirm", observe: false})
    assert confirmed.assigns.view.status == "confirm"
    assert confirmed.private.sign_in_observer_timer == nil
    assert Process.read_timer(timer) == false
    expired = deliver(confirmed, %{status: "expired", observe: false, retry: :restart})
    assert expired.assigns.view.retry == :restart
    assert expired.assigns.view.status == "expired"
    assert expired.private.sign_in_observer_timer == nil
  end

  test "challenge rotation and account confirmation retain one private session" do
    socket = socket(%{ref: self(), challenge: %{type: :qr, value: "first"}})

    expired =
      deliver(socket, %{ref: self(), status: "failed", summary: "QR expired", observe: true})

    assert is_reference(expired.private.sign_in_observer_timer.timer_ref)
    assert expired.assigns.view.challenge == nil
    replacement = deliver(expired, %{ref: self(), challenge: %{type: :qr, value: "second"}})
    assert replacement.assigns.view.challenge.value == "second"
    assert replacement.private.sign_in_observer.ref == self()
    account = %{external_id: "+15550001", display_name: nil}

    confirmed =
      deliver(replacement, %{
        ref: self(),
        status: "confirm",
        confirmation: account,
        observe: false
      })

    assert confirmed.assigns.view.status == "confirm"
    assert confirmed.assigns.view.confirmation == account
    assert confirmed.private.sign_in_observer_timer == nil
  end

  for ref <- [:provisional, {:connector, 2}] do
    test "expired QR keeps watching for its replacement for #{inspect(ref)}" do
      ref = unquote(Macro.escape(ref))
      expired = socket(%{ref: ref, challenge: nil, summary: "QR expired"})
      timer = expired.private.sign_in_observer_timer.timer_ref
      assert is_reference(timer)
      assert expired.assigns.view.challenge == nil
      replacement = deliver(expired, %{ref: ref, challenge: %{type: :qr, value: "replacement"}})
      # Each request consumes/cancels the old timer before scheduling its successor.
      assert Process.read_timer(timer) == false
      assert replacement.assigns.view.challenge.value == "replacement"
      assert replacement.private.sign_in_observer.ref == ref

      assert replacement.private.sign_in_observer.generation ==
               expired.private.sign_in_observer.generation

      Observer.dismiss(replacement)

      bounded =
        Phoenix.LiveView.put_private(expired, :sign_in_observer, %{
          expired.private.sign_in_observer
          | attempts: 89
        })

      stopped = deliver(bounded, %{ref: ref, challenge: nil})
      assert stopped.private.sign_in_observer_timer == nil
      assert stopped.assigns.view.summary == "Connection window ended; retry to continue"
    end
  end

  test "QR rendering draws modules without reflecting raw content or expired QR" do
    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "linked-device",
        attempt: %{status: "pending", challenge: %{type: :qr, value: "<script>secret</script>"}}
      )

    assert html =~ "Device connection QR code"
    refute html =~ "<script>"
    refute html =~ "secret"

    expired =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "linked-device",
        attempt: %{status: "expired", challenge: %{type: :qr, value: "old"}}
      )

    refute expired =~ "Device connection QR code"
    assert expired =~ "Start a new device sign-in"
  end

  defp socket(attrs \\ %{}) do
    Observer.open(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}, view(attrs),
      view_key: :view,
      dispatch: fn _ -> :unused end,
      max_observations: 90
    )
  end

  defp view(attrs) do
    {:ok, view} = Zaq.SignIn.view({:connector, 2}, Map.merge(%{interval_ms: 2_000}, attrs))
    view
  end

  defp response(attrs), do: {:ok, {fn _ -> :unused end, {:ok, view(attrs)}}}

  defp deliver(socket, attrs) do
    socket = Observer.request(socket, :observe)
    state = socket.private.sign_in_observer
    result = if is_map(attrs), do: response(attrs), else: {:ok, {state.dispatch, attrs}}
    Observer.result(socket, state.generation, state.in_flight, result)
  end
end
