defmodule ZaqWeb.Live.BO.Communication.HistoryLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Conversations

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  defp create_conv(user_id, overrides \\ %{}) do
    {:ok, conv} =
      Conversations.create_conversation(
        Map.merge(
          %{
            channel_type: "bo",
            channel_user_id: "u_#{System.unique_integer([:positive])}",
            user_id: user_id
          },
          overrides
        )
      )

    conv
  end

  test "renders history placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bo/history")

    assert html =~ "History"
    assert html =~ "conversations"
  end

  describe "mount" do
    test "shows conversations for current user", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "My History Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ conv.title
    end

    test "does not show conversations for other users", %{conn: conn, user: user} do
      other_user = user_fixture()
      _other_conv = create_conv(other_user.id, %{title: "Other User Conv XYZ"})
      _my_conv = create_conv(user.id, %{title: "My Own Conv"})

      {:ok, _view, html} = live(conn, ~p"/bo/history")
      refute html =~ "Other User Conv XYZ"
    end
  end

  describe "filter event" do
    test "filter by status=archived excludes active conversations", %{conn: conn, user: user} do
      _active = create_conv(user.id, %{title: "Active Conv", status: "active"})

      {:ok, archived} =
        create_conv(user.id, %{title: "Archived Conv"})
        |> then(fn c ->
          Conversations.archive_conversation(c)
        end)

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "archived", "channel_type" => "all"})

      assert html =~ archived.title
      refute html =~ "Active Conv"
    end

    test "filter by channel_type filters correctly", %{conn: conn, user: user} do
      {:ok, mm_conv} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "mm_hist_#{System.unique_integer([:positive])}",
          user_id: user.id,
          title: "MM History Conv"
        })

      _bo_conv = create_conv(user.id, %{title: "BO History Conv"})

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "all", "channel_type" => "mattermost"})

      assert html =~ mm_conv.title
    end

    test "filter with all values shows all user conversations", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "All Filter Conv"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "all", "channel_type" => "all"})

      assert html =~ conv.title
    end
  end
end
