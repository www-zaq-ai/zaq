defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.ChannelsIndexLive

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    %{conn: conn, user: user}
  end

  test "renders category cards on index", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels")

    assert has_element?(view, "#category-card-retrieval")
    assert has_element?(view, "#category-card-ingestion")
    assert has_element?(view, "#category-card-ai-agents")
  end

  test "renders provider cards on retrieval sub-page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval")

    assert has_element?(view, "#channel-card-slack")
    assert has_element?(view, "#channel-card-mattermost")
    assert has_element?(view, "#channel-card-webhook")
  end

  test "renders provider cards on ingestion sub-page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/ingestion")

    assert has_element?(view, "a", "All Channels")
    assert has_element?(view, "#channel-card-zaq_local")
    assert has_element?(view, "#channel-card-google_drive")
    assert has_element?(view, "#channel-card-sharepoint")
  end

  test "shows active count for configured provider", %{conn: conn} do
    insert_channel_config(%{provider: "slack", name: "Slack Ops"})

    {:ok, _view, html} = live(conn, ~p"/bo/channels")

    assert html =~ "1 active"
  end

  test "shows service unavailable page when channels service is down", %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels")

    assert has_element?(view, "h2", "Service Unavailable")
  end

  describe "module helpers" do
    test "stat_for returns count or default zero" do
      stats = %{slack: 2}

      assert ChannelsIndexLive.stat_for(stats, "slack") == 2
      assert ChannelsIndexLive.stat_for(stats, "teams") == 0
    end

    test "retrieval_total and ingestion_total aggregate known providers" do
      base_stats =
        ~w(slack teams mattermost discord telegram webhook zaq_local google_drive sharepoint)
        |> Map.new(fn provider -> {String.to_atom(provider), 0} end)

      stats = %{base_stats | slack: 2, mattermost: 1, zaq_local: 3, google_drive: 4}

      assert ChannelsIndexLive.retrieval_total(stats) == 3
      assert ChannelsIndexLive.ingestion_total(stats) == 7
    end

    test "provider_path handles zaq_local special case and scoped paths" do
      assert ChannelsIndexLive.provider_path(:ingestion, "zaq_local") == "/bo/ingestion"

      assert ChannelsIndexLive.provider_path(:retrieval, "slack") ==
               "/bo/channels/retrieval/slack"

      assert ChannelsIndexLive.provider_path(:ingestion, "sharepoint") ==
               "/bo/channels/ingestion/sharepoint"
    end
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
end
