defmodule ZaqWeb.Live.BO.Communication.WhatsAppOnboardingTest do
  use ZaqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.TestSupport.Eventually
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  test "new WhatsApp scans then confirms detected account without a manual form", %{conn: conn} do
    Mox.stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
    Zaq.WhatsAppFixtures.configure_channels(WhatsAppFlowAdapter)
    start_supervised!({Transport, observer: self()})
    user = super_admin_fixture(%{must_change_password: false})
    count = Repo.aggregate(ChannelConfig, :count)

    {:ok, view, _} =
      live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/channels/retrieval/whatsapp")

    view |> element("#new-config-button") |> render_click()
    render_async(view, 5_000)
    assert_receive {:whatsapp_connected_config, options}
    refute has_element?(view, "#config-form")

    assert eventually(fn ->
             render_async(view, 5_000)
             has_element?(view, "#linked-device-pairing svg")
           end)

    assert Repo.aggregate(ChannelConfig, :count) == count
    :erlang.trace(view.pid, true, [:receive])
    :ok = Transport.scan(options.profile, "fixture-qr:#{options.profile}", reconnecting: true)
    view_pid = view.pid
    assert_receive {:trace, ^view_pid, :receive, {:sign_in_tick, _, _}}, 3_000
    render_async(view, 5_000)
    assert render(view) =~ "Reconnecting with the linked account"
    refute has_element?(view, "#linked-device-pairing svg")
    :erlang.trace(view.pid, false, [:receive])
    :ok = Transport.finish_reconnect(options.profile)

    assert eventually(fn ->
             render_async(view, 5_000)
             has_element?(view, "#linked-device-account-id", "+15550001")
           end)

    # A late Retry click must inspect the already-linked session, not cancel it
    # and begin another QR handshake.
    render_click(view, "retry_linked_device", %{})
    render_async(view, 5_000)
    assert has_element?(view, "#linked-device-account-id", "+15550001")
    refute has_element?(view, "#linked-device-pairing svg")
    refute_received {:whatsapp_connected_config, _}
    assert {:ok, _} = Transport.resolve_conn(profile: options.profile)

    assert render(view) =~ "Support account"
    assert Repo.aggregate(ChannelConfig, :count) == count
    view |> element("button", "Confirm account") |> render_click()
    render_async(view, 5_000)
    assert eventually(fn -> not has_element?(view, "#linked-device-pairing") end)
    config = Repo.get_by!(ChannelConfig, name: "Support account", provider: "whatsapp")
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    assert Repo.aggregate(ChannelConfig, :count) == count + 1
    assert has_element?(view, "#config-card-#{config.id}", "Support account")
    assert has_element?(view, "#config-card-#{config.id}", "Active")
    assert has_element?(view, "#config-card-#{config.id}", "WhatsApp - +15550001")
    view |> element("#open-test-config-#{config.id}") |> render_click()
    assert has_element?(view, "#test-connection-form label[for='test-recipient']", "Phone number")
    assert has_element?(view, "#test-recipient[type='tel'][placeholder='e.g. 96170123456']")
    view |> element("#test-connection-form button", "Close") |> render_click()
    assert has_element?(view, "#edit-config-#{config.id}")
    view |> element("#edit-config-#{config.id}") |> render_click()
    refute has_element?(view, "input[name='form[settings][jido_chat][bot_user_id]']")
    refute has_element?(view, "input[name='form[settings][jido_chat][bot_name]']")
  end

  defp eventually(probe),
    do:
      Eventually.eventually(probe,
        timeout: 6_000,
        interval: 20,
        label: "onboarding UI"
      )
end
