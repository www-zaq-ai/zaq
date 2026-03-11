defmodule ZaqWeb.Live.BO.Communication.ChannelsIndexLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

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

  test "shows active count for configured provider", %{conn: conn} do
    insert_channel_config(%{provider: "slack", name: "Slack Ops"})

    {:ok, _view, html} = live(conn, ~p"/bo/channels")

    assert html =~ "1 active"
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
