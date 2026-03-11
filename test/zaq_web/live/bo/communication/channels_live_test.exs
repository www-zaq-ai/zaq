defmodule ZaqWeb.Live.BO.Communication.ChannelsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

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

    assert html =~ "Kind can&#39;t be blank"
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

  test "shows retrieval channel action errors when no enabled config exists", %{conn: conn} do
    insert_channel_config(%{enabled: false})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/mattermost")

    render_hook(view, "fetch_teams", %{})
    assert render(view) =~ "No enabled Mattermost config found."

    render_hook(view, "select_team", %{"team-id" => "t-1", "team-name" => "Platform"})
    assert render(view) =~ "No enabled Mattermost config found."

    render_hook(view, "add_channel", %{"channel-id" => "c-1", "channel-name" => "general"})
    assert render(view) =~ "No enabled Mattermost config found."
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
