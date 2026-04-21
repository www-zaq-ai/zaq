defmodule ZaqWeb.Live.BO.Communication.ChannelsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Repo

  defmodule BridgeFake do
    def test_connection(_config, _channel_id) do
      fetch_state(:test_connection, {:ok, %{id: "ok"}})
    end

    def start_runtime(_config), do: fetch_state(:start_runtime, :ok)
    def stop_runtime(_config), do: fetch_state(:stop_runtime, :ok)

    def put(key, value), do: put_state(key, value)

    defp fetch_state(key, default) do
      state = :persistent_term.get(__MODULE__, %{})
      Map.get(state, key, default)
    end

    defp put_state(key, value) do
      state = :persistent_term.get(__MODULE__, %{})
      :persistent_term.put(__MODULE__, Map.put(state, key, value))
    end
  end

  defmodule MattermostAPIFake do
    def send_message(_channel_id, _message), do: fetch_state(:send_message, {:ok, %{id: "sent"}})
    def clear_channel(_channel_id), do: fetch_state(:clear_channel, :ok)
    def list_teams(_cfg), do: fetch_state(:list_teams, {:ok, []})
    def list_public_channels(_cfg, _team_id), do: fetch_state(:list_public_channels, {:ok, []})

    def put(key, value), do: put_state(key, value)

    defp fetch_state(key, default) do
      state = :persistent_term.get(__MODULE__, %{})
      Map.get(state, key, default)
    end

    defp put_state(key, value) do
      state = :persistent_term.get(__MODULE__, %{})
      :persistent_term.put(__MODULE__, Map.put(state, key, value))
    end
  end

  defmodule HTTPClientFake do
    def get(_url, _opts), do: fetch!(:response)

    def put_response(response), do: :persistent_term.put(__MODULE__, %{response: response})

    defp fetch!(key) do
      state = :persistent_term.get(__MODULE__, %{})
      Map.fetch!(state, key)
    end
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    previous_channels = Application.get_env(:zaq, :channels, %{})

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: BridgeFake, ingress_mode: :websocket},
      web: %{bridge: Zaq.Channels.WebBridge},
      email: %{bridge: Zaq.Channels.EmailBridge}
    })

    Application.put_env(:zaq, :channels_live_mattermost_api_module, MattermostAPIFake)
    Application.put_env(:zaq, :channels_live_http_client, HTTPClientFake)

    :persistent_term.put(BridgeFake, %{})
    :persistent_term.put(MattermostAPIFake, %{})
    :persistent_term.put(HTTPClientFake, %{})

    on_exit(fn ->
      Application.delete_env(:zaq, :channels_live_mattermost_api_module)
      Application.delete_env(:zaq, :channels_live_http_client)
      Application.put_env(:zaq, :channels, previous_channels)

      :persistent_term.erase(BridgeFake)
      :persistent_term.erase(MattermostAPIFake)
      :persistent_term.erase(HTTPClientFake)
    end)

    %{conn: conn, user: user}
  end

  test "shows empty state and modal controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    assert has_element?(view, "#configs-empty-state")

    view |> element("#new-config-button") |> render_click()
    assert has_element?(view, "#config-form")

    view |> element("button[phx-click=\"close_modal\"]") |> render_click()
    refute has_element?(view, "#config-form")
  end

  test "renders agent routing controls for provider default and retrieval channels", %{conn: conn} do
    config = insert_channel_config(%{})
    retrieval = insert_retrieval_channel(config)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    assert has_element?(view, "#provider-default-agent-select")
    assert has_element?(view, "#retrieval-channel-agent-select-#{retrieval.id}")
  end

  test "toggles and deletes a config", %{conn: conn} do
    config = insert_channel_config(%{})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    assert has_element?(view, "#config-card-#{config.id}")

    view |> element("#toggle-config-#{config.id}") |> render_click()
    refute Repo.get!(ChannelConfig, config.id).enabled

    view |> element("#confirm-delete-config-#{config.id}") |> render_click()
    view |> element("#delete-config-button") |> render_click()

    refute Repo.get(ChannelConfig, config.id)
  end

  test "toggles and removes retrieval channels", %{conn: conn} do
    config = insert_channel_config(%{})
    retrieval = insert_retrieval_channel(config)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    assert has_element?(view, "#retrieval-channel-#{retrieval.id}")

    view |> element("#toggle-retrieval-channel-#{retrieval.id}") |> render_click()
    refute Repo.get!(RetrievalChannel, retrieval.id).active

    view |> element("#confirm-remove-retrieval-channel-#{retrieval.id}") |> render_click()
    view |> element("#remove-retrieval-channel-button") |> render_click()

    refute Repo.get(RetrievalChannel, retrieval.id)
  end

  test "toggle retrieval channel flips both directions", %{conn: conn} do
    config = insert_channel_config(%{})
    retrieval = insert_retrieval_channel(config)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view |> element("#toggle-retrieval-channel-#{retrieval.id}") |> render_click()
    refute Repo.get!(RetrievalChannel, retrieval.id).active

    view |> element("#toggle-retrieval-channel-#{retrieval.id}") |> render_click()
    assert Repo.get!(RetrievalChannel, retrieval.id).active
  end

  test "shows validate/save errors when config is invalid", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")
    initial_count = Repo.aggregate(ChannelConfig, :count)

    view |> element("#new-config-button") |> render_click()

    view
    |> element("#config-form")
    |> render_change(%{
      "form" => %{"provider" => "mattermost", "name" => "", "url" => "", "token" => ""}
    })

    html =
      view
      |> element("#config-form")
      |> render_submit(%{
        "form" => %{"provider" => "mattermost", "name" => "", "url" => "", "token" => ""}
      })

    assert html =~ "Name can&#39;t be blank"
    assert Repo.aggregate(ChannelConfig, :count) == initial_count
    assert has_element?(view, "#config-form")
  end

  test "supports open/close combinations for destructive modals", %{conn: conn} do
    config = insert_channel_config(%{})
    retrieval = insert_retrieval_channel(config)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view |> element("#confirm-delete-config-#{config.id}") |> render_click()
    assert render(view) =~ "Confirm Delete"
    render_hook(view, "cancel_delete", %{})
    refute render(view) =~ "Confirm Delete"

    view |> element("#confirm-remove-retrieval-channel-#{retrieval.id}") |> render_click()
    assert render(view) =~ "Remove Channel?"
    render_hook(view, "cancel_remove_channel", %{})
    refute render(view) =~ "Remove Channel?"
  end

  test "handles missing config on delete branch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    render_hook(view, "confirm_delete", %{"id" => "999999"})
    render_hook(view, "delete", %{})

    assert render(view) =~ "Config not found."
  end

  test "runs clear modal flows and error path without enabled config", %{conn: conn} do
    insert_channel_config(%{enabled: false})
    MattermostAPIFake.put(:clear_channel, {:error, :mattermost_not_configured})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view
    |> element("form[phx-submit=\"prompt_clear\"]")
    |> render_submit(%{"channel_id" => "ch-123"})

    assert render(view) =~ "Clear Channel?"
    assert render(view) =~ "ch-123"

    render_hook(view, "cancel_clear", %{})
    refute render(view) =~ "Clear Channel?"

    view
    |> element("form[phx-submit=\"prompt_clear\"]")
    |> render_submit(%{"channel_id" => "ch-123"})

    render_hook(view, "run_clear", %{})
    assert render(view) =~ "mattermost_not_configured"
  end

  test "run_clear success branch updates clear status", %{conn: conn} do
    insert_channel_config(%{})
    MattermostAPIFake.put(:clear_channel, :ok)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view
    |> element("form[phx-submit=\"prompt_clear\"]")
    |> render_submit(%{"channel_id" => "ops-123"})

    render_hook(view, "run_clear", %{})

    assert render(view) =~ "Channel cleared successfully."
    refute render(view) =~ "Clear Channel?"
  end

  test "shows retrieval channel action errors when no enabled config exists", %{conn: conn} do
    insert_channel_config(%{enabled: false})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    render_hook(view, "fetch_teams", %{})
    assert render(view) =~ "No enabled Mattermost config found."

    render_hook(view, "select_team", %{"team_id" => "t-1", "team_name" => "Platform"})
    assert render(view) =~ "No enabled Mattermost config found."

    render_hook(view, "add_channel", %{"channel-id" => "c-1", "channel-name" => "general"})
    assert render(view) =~ "No enabled Mattermost config found."
  end

  test "handles run_test success and close_test", %{conn: conn} do
    config = insert_channel_config(%{})
    BridgeFake.put(:test_connection, {:ok, %{id: "post-1"}})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view |> element("#open-test-config-#{config.id}") |> render_click()
    assert has_element?(view, "#test-connection-form")

    view
    |> element("#test-connection-form")
    |> render_submit(%{"channel_id" => " channel-1 "})

    assert render(view) =~ "Test message sent successfully!"

    render_hook(view, "close_test", %{})
    refute has_element?(view, "#test-connection-form")
  end

  test "handles run_test error branch", %{conn: conn} do
    config = insert_channel_config(%{})
    BridgeFake.put(:test_connection, {:error, :unauthorized})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view |> element("#open-test-config-#{config.id}") |> render_click()

    view
    |> element("#test-connection-form")
    |> render_submit(%{"channel_id" => "channel-1"})

    assert render(view) =~ "Test failed"
    assert render(view) =~ "unauthorized"
  end

  test "handles send_message success, error, and reset_send", %{conn: conn} do
    insert_channel_config(%{})
    MattermostAPIFake.put(:send_message, {:ok, %{id: "posted"}})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view
    |> element("form[phx-submit=\"send_message\"]")
    |> render_submit(%{"channel_id" => "ch-1", "message" => "hello"})

    assert render(view) =~ "Message sent!"

    render_hook(view, "reset_send", %{})
    refute render(view) =~ "Message sent!"

    MattermostAPIFake.put(:send_message, {:error, :blocked})

    view
    |> element("form[phx-submit=\"send_message\"]")
    |> render_submit(%{"channel_id" => "ch-1", "message" => "bad"})

    assert render(view) =~ "Failed to send"
    assert render(view) =~ "blocked"
  end

  test "loads posts success and handles HTTP/transport errors", %{conn: conn} do
    insert_channel_config(%{url: "https://mattermost.test"})

    HTTPClientFake.put_response({
      :ok,
      %Req.Response{
        status: 200,
        body:
          Jason.encode!(%{
            "order" => ["p2", "p1"],
            "posts" => %{
              "p1" => %{"id" => "p1", "message" => "hello", "user_id" => "u1", "create_at" => 1},
              "p2" => %{"id" => "p2", "message" => "world", "user_id" => "u2", "create_at" => 2}
            }
          })
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view
    |> element("form[phx-submit=\"load_posts\"]")
    |> render_submit(%{"channel_id" => "ch-1"})

    html = render(view)
    assert html =~ "2 posts loaded"
    assert html =~ "world"

    HTTPClientFake.put_response({:ok, %Req.Response{status: 500, body: "boom"}})

    view
    |> element("form[phx-submit=\"load_posts\"]")
    |> render_submit(%{"channel_id" => "ch-1"})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.posts_status == :error
    assert state.socket.assigns.posts == "HTTP 500"

    HTTPClientFake.put_response({:error, %Req.TransportError{reason: :econnrefused}})

    view
    |> element("form[phx-submit=\"load_posts\"]")
    |> render_submit(%{"channel_id" => "ch-1"})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.posts_status == :error
    assert state.socket.assigns.posts =~ "econnrefused"
  end

  test "load_posts handles nil config branch", %{conn: conn} do
    insert_channel_config(%{enabled: false})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view
    |> element("form[phx-submit=\"load_posts\"]")
    |> render_submit(%{"channel_id" => "ch-no-config"})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.posts_status == :error
    assert state.socket.assigns.posts == []
  end

  test "save supports happy paths for new and edit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    view |> element("#new-config-button") |> render_click()

    view
    |> element("#config-form")
    |> render_submit(%{
      "form" => %{
        "provider" => "mattermost",
        "kind" => "retrieval",
        "name" => "Mattermost Alpha",
        "url" => "https://mm-alpha.local",
        "token" => "token-alpha",
        "enabled" => "true"
      }
    })

    assert render(view) =~ "Channel config saved."

    config = Repo.get_by!(ChannelConfig, name: "Mattermost Alpha")

    view |> element("#edit-config-#{config.id}") |> render_click()

    view
    |> element("#config-form")
    |> render_submit(%{
      "form" => %{
        "name" => "Mattermost Beta",
        "url" => "https://mm-beta.local",
        "token" => "token-beta",
        "enabled" => "true"
      }
    })

    assert Repo.get!(ChannelConfig, config.id).name == "Mattermost Beta"
    assert render(view) =~ "Channel config saved."
  end

  test "save shows token encryption error when encryption key is invalid", %{conn: conn} do
    previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: "invalid",
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")
    initial_count = Repo.aggregate(ChannelConfig, :count)

    view |> element("#new-config-button") |> render_click()

    html =
      view
      |> element("#config-form")
      |> render_submit(%{
        "form" => %{
          "provider" => "mattermost",
          "kind" => "retrieval",
          "name" => "Mattermost Strict",
          "url" => "https://mm-strict.local",
          "token" => "token-strict",
          "enabled" => "true"
        }
      })

    assert html =~ "could not be encrypted"
    assert Repo.aggregate(ChannelConfig, :count) == initial_count
    assert has_element?(view, "#config-form")
  end

  test "service unavailable guard ignores events", %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)
    insert_channel_config(%{})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    assert has_element?(view, "#configs-empty-state")

    render_hook(view, "open_modal", %{"action" => "new"})
    refute has_element?(view, "#config-form")

    render_hook(view, "fetch_teams", %{})
    refute render(view) =~ "No enabled Mattermost config found."
  end

  test "fetch_teams and select_team support success and error paths", %{conn: conn} do
    config = insert_channel_config(%{})
    insert_retrieval_channel(config)

    MattermostAPIFake.put(
      :list_teams,
      {:ok, [%{id: "t1", display_name: "Platform", name: "platform"}]}
    )

    MattermostAPIFake.put(
      :list_public_channels,
      {:ok,
       [
         %{id: "channel-1", display_name: "engineering", purpose: "", type: "O"},
         %{id: "channel-2", display_name: "qa", purpose: "QA", type: "O"}
       ]}
    )

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    render_hook(view, "fetch_teams", %{})
    assert render(view) =~ "Select a Team"
    assert render(view) =~ "Platform"

    render_hook(view, "select_team", %{"team_id" => "t1", "team_name" => "Platform"})
    assert render(view) =~ "Public Channels in Platform"
    assert has_element?(view, "button[phx-click='add_channel'][phx-value-channel-id='channel-2']")
    refute has_element?(view, "button[phx-click='add_channel'][phx-value-channel-id='channel-1']")

    MattermostAPIFake.put(:list_teams, {:error, :unauthorized})
    render_hook(view, "fetch_teams", %{})
    assert render(view) =~ "Failed to load teams"

    MattermostAPIFake.put(:list_public_channels, {:error, :timeout})
    render_hook(view, "select_team", %{"team_id" => "t1", "team_name" => "Platform"})
    assert render(view) =~ "Failed to load channels"
  end

  test "add_channel handles success and insert error", %{conn: conn} do
    config = insert_channel_config(%{})

    MattermostAPIFake.put(
      :list_teams,
      {:ok, [%{id: "t1", display_name: "Platform", name: "platform"}]}
    )

    MattermostAPIFake.put(
      :list_public_channels,
      {:ok, [%{id: "c-2", display_name: "general", purpose: "", type: "O"}]}
    )

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    render_hook(view, "fetch_teams", %{})
    render_hook(view, "select_team", %{"team_id" => "t1", "team_name" => "Platform"})
    render_hook(view, "add_channel", %{"channel-id" => "c-2", "channel-name" => "general"})

    assert Repo.get_by(RetrievalChannel, channel_config_id: config.id, channel_id: "c-2")
    assert render(view) =~ "added as retrieval channel"

    render_hook(view, "add_channel", %{"channel-id" => "c-2", "channel-name" => "general"})
    assert render(view) =~ "Failed to add channel"
  end

  defp insert_channel_config(attrs) do
    params =
      %{
        name: "Mattermost Main",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://mattermost.local",
        token: "test-token",
        enabled: true
      }
      |> Map.merge(attrs)

    %ChannelConfig{}
    |> ChannelConfig.changeset(params)
    |> Repo.insert!()
  end

  defp insert_retrieval_channel(config) do
    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "channel-1",
      channel_name: "engineering",
      team_id: "team-1",
      team_name: "Platform",
      active: true
    })
    |> Repo.insert!()
  end
end
