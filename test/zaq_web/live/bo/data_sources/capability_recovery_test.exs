defmodule ZaqWeb.Live.BO.DataSources.CapabilityRecoveryTest do
  use ZaqWeb.ConnCase, async: false
  use ExUnitProperties

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.ChannelCapabilityFixtures

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.DataSources.ProviderLive

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  for provider <- [:disk, :google_drive, :sharepoint] do
    test "#{provider} capabilities recover on reopen and cache success", %{conn: conn} do
      channels = remove_capability_bridge(unquote(provider))
      observe_capability_lookups()
      {:ok, view, _} = live(conn, "/bo/channels/data_source/#{unquote(provider)}")
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

  property "capability reopening preserves drafts and cached folder state" do
    check all(
            name <- string(:alphanumeric, max_length: 30),
            folder_id <- positive_integer(),
            failed? <- boolean(),
            max_runs: 25
          ) do
      socket =
        socket_with(%{
          provider: "disk",
          capabilities_snapshot: %{},
          capabilities_error: failed?,
          capability_modal_open: false,
          form: %{params: %{"name" => name}},
          root_folders_by_config: %{1 => [%{id: folder_id}]},
          root_folder_meta_by_config: %{1 => %{next_page_token: "next"}},
          grants_by_config: %{1 => %{id: 2}},
          folder_info_modal: %{config_id: 1, folder: %{id: folder_id}}
        })

      assert {:noreply, opened} = ProviderLive.handle_event("open_capabilities", %{}, socket)
      assert opened.assigns.capability_modal_open
      refute opened.assigns.capabilities_error

      ignored = [
        :__changed__,
        :capability_modal_open,
        :capabilities_error,
        :capabilities_snapshot
      ]

      assert Map.drop(opened.assigns, ignored) == Map.drop(socket.assigns, ignored)
      if !failed?, do: assert(opened.assigns.capabilities_snapshot == %{})
    end
  end

  test "connector refreshes update capability failure state in both directions", %{user: user} do
    original_base_url = Zaq.System.get_global_base_url()
    :ok = Zaq.System.set_global_base_url("https://zaq.example")
    on_exit(fn -> Zaq.System.set_global_base_url(original_base_url) end)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Capability refresh",
        provider: "google_drive",
        kind: "data_source",
        enabled: true
      })
      |> Repo.insert!()

    channels = remove_capability_bridge(:google_drive)

    socket =
      socket_with(%{
        current_user: user,
        provider: "google_drive",
        capabilities_snapshot: %{},
        capabilities_error: false,
        root_folders_by_config: %{},
        root_folder_meta_by_config: %{},
        stats_errors_by_config: %{}
      })

    assert {:noreply, failed} =
             ProviderLive.handle_event("toggle_enabled", %{"id" => to_string(config.id)}, socket)

    assert failed.assigns.capabilities_error
    refute Repo.get!(ChannelConfig, config.id).enabled

    Application.put_env(:zaq, :channels, channels)
    saved_config = Repo.get!(ChannelConfig, config.id)

    editing =
      Phoenix.Component.assign(failed,
        modal: :edit,
        changeset: ChannelConfig.changeset(saved_config, %{}),
        form: nil,
        modal_errors: []
      )

    assert {:noreply, recovered} =
             ProviderLive.handle_event("save", %{"form" => %{"name" => "Recovered"}}, editing)

    assert recovered.assigns.modal == nil, inspect(recovered.assigns.modal_errors)
    refute recovered.assigns.capabilities_error
    assert recovered.assigns.capabilities_snapshot.resolved != %{}
    assert Repo.get!(ChannelConfig, config.id).name == "Recovered"
  end

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}
  end
end
