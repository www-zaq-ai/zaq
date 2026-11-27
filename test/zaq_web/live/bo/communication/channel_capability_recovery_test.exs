defmodule ZaqWeb.Live.BO.Communication.ChannelCapabilityRecoveryTest do
  use ZaqWeb.ConnCase, async: false
  use ExUnitProperties

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.ChannelCapabilityFixtures

  alias ZaqWeb.Live.BO.Communication.ChannelsLive

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  for provider <- [:mattermost, :discord, :telegram] do
    test "#{provider} capabilities recover on reopen and cache success", %{conn: conn} do
      channels = remove_capability_bridge(unquote(provider))
      observe_capability_lookups()
      {:ok, view, _} = live(conn, "/bo/channels/retrieval/#{unquote(provider)}")
      initial_count = capability_lookup_count()

      view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
      assert has_element?(view, "#capabilities-modal", "Capabilities unavailable")
      assert capability_lookup_count() == initial_count + 1
      view |> element("[data-testid='channel-capabilities-close']") |> render_click()

      Application.put_env(:zaq, :channels, channels)
      view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
      refute has_element?(view, "#capabilities-modal", "Capabilities unavailable")
      assert has_element?(view, "#capabilities-modal li")
      assert capability_lookup_count() == initial_count + 2

      view |> element("[data-testid='channel-capabilities-close']") |> render_click()
      remove_capability_bridge(unquote(provider))
      view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
      refute has_element?(view, "#capabilities-modal", "Capabilities unavailable")
      assert has_element?(view, "#capabilities-modal li")
      assert capability_lookup_count() == initial_count + 2
    end
  end

  property "successful capability reopening preserves snapshots and unrelated draft state" do
    observe_capability_lookups()

    check all(
            name <- string(:alphanumeric, max_length: 30),
            selected_id <- positive_integer(),
            snapshot <- member_of([%{}, %{resolved: %{text: :native}}]),
            max_runs: 25
          ) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          capabilities_snapshot: snapshot,
          capabilities_error: false,
          capability_modal_open: false,
          selected_config_id: selected_id,
          form: %{params: %{"name" => name}}
        }
      }

      assert {:noreply, opened} = ChannelsLive.handle_event("open_capabilities", %{}, socket)
      assert opened.assigns.capability_modal_open
      ignored = [:__changed__, :capability_modal_open]
      assert Map.drop(opened.assigns, ignored) == Map.drop(socket.assigns, ignored)
    end

    assert capability_lookup_count() == 0
  end
end
