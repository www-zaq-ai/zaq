defmodule ZaqWeb.Live.BO.Communication.LinkedDeviceUITest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.LinkedDevicePairing
  alias ZaqWeb.Live.BO.Communication.LinkedDeviceUI

  test "poll ticks are consumed once without rotating the modal result generation" do
    socket = Phoenix.Component.assign(socket(), :current_user, nil)
    generation = socket.assigns.linked_device_modal.generation
    watching = LinkedDeviceUI.result(socket, generation, {:ok, {:ok, %{phase: :pending}}})
    timer = watching.private.linked_device_timer

    assert timer.interval_ms == 2_000
    assert LinkedDeviceUI.poll(watching, generation, make_ref()) == watching
    consumed = LinkedDeviceUI.poll(watching, generation, timer.generation)
    assert consumed.private.linked_device_timer == nil
    assert consumed.assigns.linked_device_modal.generation == generation
    assert LinkedDeviceUI.poll(consumed, generation, timer.generation) == consumed

    successor = LinkedDeviceUI.result(consumed, generation, {:ok, {:ok, %{phase: :pending}}})
    refute successor.private.linked_device_timer.generation == timer.generation
    assert LinkedDeviceUI.poll(successor, generation, timer.generation) == successor
    LinkedDeviceUI.close(successor)
  end

  test "stale result and timer cannot update another selected connector" do
    socket = socket()
    assert LinkedDeviceUI.result(socket, make_ref(), {:ok, {:ok, %{qr: "wrong"}}}) == socket
    assert LinkedDeviceUI.refresh(socket, make_ref()) == socket
    assert socket.assigns.linked_device_modal.config_id == 2
  end

  test "closing cancels polling and clears QR material" do
    socket = socket()

    socket =
      LinkedDeviceUI.result(
        socket,
        socket.assigns.linked_device_modal.generation,
        {:ok, {:ok, %{phase: :pairing, qr: "current"}}}
      )

    timer = socket.private.linked_device_timer.timer_ref
    closed = LinkedDeviceUI.close(socket)
    assert closed.assigns.linked_device_modal == nil
    assert Process.read_timer(timer) == false

    assert LinkedDeviceUI.result(
             closed,
             socket.assigns.linked_device_modal.generation,
             {:ok, {:ok, %{qr: "late"}}}
           ) == closed
  end

  test "retry failure clears QR and polling is bounded" do
    socket = socket()
    generation = socket.assigns.linked_device_modal.generation
    failed = LinkedDeviceUI.result(socket, generation, {:ok, {:error, :restart_failed}})
    assert failed.assigns.linked_device_modal.status.phase == :failed
    refute Map.has_key?(failed.assigns.linked_device_modal.status, :qr)
    modal = %{socket.assigns.linked_device_modal | attempts: 89}
    socket = Phoenix.Component.assign(socket, :linked_device_modal, modal)

    expired =
      LinkedDeviceUI.result(socket, generation, {:ok, {:ok, %{phase: :pairing, qr: "old"}}})

    assert expired.assigns.linked_device_modal.status.phase == :expired
    assert expired.private.linked_device_timer == nil
  end

  test "provisional retry preserves the session even when the UI previously saw failure" do
    socket = socket()

    modal =
      Map.merge(socket.assigns.linked_device_modal, %{
        config_id: nil,
        session: self(),
        status: %{phase: :failed},
        attempts: 12
      })

    socket =
      socket
      |> Phoenix.Component.assign(:linked_device_modal, modal)
      |> Phoenix.Component.assign(:current_user, nil)

    retried = LinkedDeviceUI.retry(socket)
    assert retried.assigns.linked_device_modal.session == self()
    refute retried.assigns.linked_device_modal.generation == modal.generation
    assert retried.assigns.linked_device_modal.status.phase == :pending
    assert retried.assigns.linked_device_modal.attempts == 0
  end

  test "recovering pairing keeps polling and an expired session is explicitly distinguished" do
    socket = socket()
    generation = socket.assigns.linked_device_modal.generation

    pending =
      LinkedDeviceUI.result(
        socket,
        generation,
        {:ok, {:ok, %{phase: :pending, summary: "Reconnecting with the linked account", qr: nil}}}
      )

    assert is_reference(pending.private.linked_device_timer.timer_ref)
    confirmed = LinkedDeviceUI.result(pending, generation, {:ok, {:ok, %{phase: :confirm}}})
    assert confirmed.assigns.linked_device_modal.status.phase == :confirm
    assert confirmed.private.linked_device_timer == nil
    assert Process.read_timer(pending.private.linked_device_timer.timer_ref) == false
    expired = LinkedDeviceUI.result(socket, generation, {:ok, {:error, :pairing_expired}})
    assert expired.assigns.linked_device_modal.status.session_expired
    assert expired.assigns.linked_device_modal.status.phase == :expired
    assert expired.private.linked_device_timer == nil
  end

  test "shared challenge rotation and account confirmation retain one session" do
    socket = socket()
    modal = Map.merge(socket.assigns.linked_device_modal, %{config_id: nil, session: self()})
    socket = Phoenix.Component.assign(socket, :linked_device_modal, modal)

    first =
      LinkedDeviceUI.result(socket, modal.generation, {
        :ok,
        {:ok, %{phase: :challenge, session: self(), challenge: %{type: :qr, value: "first"}}}
      })

    assert first.assigns.linked_device_modal.status == %{
             phase: :pairing,
             session: self(),
             challenge: %{type: :qr, value: "first"},
             qr: "first"
           }

    expired =
      LinkedDeviceUI.result(first, modal.generation, {
        :ok,
        {:ok, %{phase: :failed, session: self(), summary: "QR expired"}}
      })

    assert is_reference(expired.private.linked_device_timer.timer_ref)
    refute Map.has_key?(expired.assigns.linked_device_modal.status, :qr)

    replacement =
      LinkedDeviceUI.result(expired, modal.generation, {
        :ok,
        {:ok, %{phase: :challenge, session: self(), challenge: %{type: :qr, value: "second"}}}
      })

    assert replacement.assigns.linked_device_modal.status.qr == "second"
    assert replacement.assigns.linked_device_modal.session == self()

    account = %{external_id: "+15550001", display_name: nil}

    confirmed =
      LinkedDeviceUI.result(replacement, modal.generation, {
        :ok,
        {:ok, %{phase: :authenticated, session: self(), account: account}}
      })

    assert confirmed.assigns.linked_device_modal.status.phase == :confirm
    assert confirmed.assigns.linked_device_modal.status.account == account
    assert confirmed.private.linked_device_timer == nil
  end

  for config_id <- [nil, 2] do
    test "expired QR keeps watching for its replacement for config #{inspect(config_id)}" do
      socket = socket()

      modal =
        Map.merge(socket.assigns.linked_device_modal, %{
          config_id: unquote(config_id),
          session: self()
        })

      socket = Phoenix.Component.assign(socket, :linked_device_modal, modal)

      expired =
        LinkedDeviceUI.result(socket, modal.generation, {:ok, {:ok, %{phase: :expired, qr: nil}}})

      timer = expired.private.linked_device_timer.timer_ref
      assert is_reference(timer)
      assert expired.assigns.linked_device_modal.status.qr == nil

      replaced =
        LinkedDeviceUI.result(
          expired,
          modal.generation,
          {:ok, {:ok, %{phase: :pairing, qr: "replacement"}}}
        )

      assert Process.read_timer(timer) == false
      assert replaced.assigns.linked_device_modal.status.qr == "replacement"
      assert replaced.assigns.linked_device_modal.session == self()
      assert replaced.assigns.linked_device_modal.generation == modal.generation
      Process.cancel_timer(replaced.private.linked_device_timer.timer_ref)

      bounded =
        Phoenix.Component.assign(expired, :linked_device_modal, %{
          expired.assigns.linked_device_modal
          | attempts: 89
        })

      stopped =
        LinkedDeviceUI.result(
          bounded,
          modal.generation,
          {:ok, {:ok, %{phase: :expired, qr: nil}}}
        )

      assert stopped.private.linked_device_timer == nil

      assert stopped.assigns.linked_device_modal.status.summary ==
               "Connection window ended; retry to continue"
    end
  end

  test "QR rendering draws modules without reflecting raw content or exposing expired QR" do
    html =
      render_component(&LinkedDevicePairing.modal/1,
        name: "Second account",
        provider: "Example",
        status: %{phase: :pairing, qr: "<script>secret</script>", summary: "Scan"}
      )

    assert html =~ "Device connection QR code"
    refute html =~ "<script>"
    refute html =~ "secret"

    expired =
      render_component(&LinkedDevicePairing.modal/1,
        name: "Second account",
        provider: "Example",
        status: %{phase: :expired, qr: "old", summary: "Expired"},
        history_disabled: true
      )

    refute expired =~ "Device connection QR code"
    assert expired =~ "Retry connection"
    assert expired =~ "History sync is disabled"
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        provider: "whatsapp",
        provider_label: "WhatsApp",
        linked_device_modal: %{
          config_id: 2,
          name: "Second",
          generation: make_ref(),
          attempts: 0,
          status: %{qr: "current"}
        }
      }
    }
  end
end
