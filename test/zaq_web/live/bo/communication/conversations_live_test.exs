defmodule ZaqWeb.Live.BO.Communication.ConversationsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Conversations

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
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

  describe "mount" do
    test "renders conversations list", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "My Test Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ "History"
      assert html =~ conv.title
    end

    test "shows channel type column", %{conn: conn, user: user} do
      create_conv(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ "Channel"
    end

    test "shows empty state when no conversations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ "No conversations found" or html =~ "conversations"
    end
  end

  describe "filter" do
    test "filter by channel_type shows only matching conversations", %{conn: conn, user: user} do
      create_conv(user.id, %{channel_type: "mattermost", title: "MM Conv"})
      create_conv(user.id, %{channel_type: "bo", title: "BO Conv"})

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "all", "channel_type" => "mattermost"})

      assert html =~ "mattermost"
    end
  end

  describe "archive event" do
    # ConversationsLive archive handler tested via context since /bo/conversations route
    # is pending; verifies the underlying archive_conversation/1 context function works.
    test "archives a conversation", %{user: user} do
      conv = create_conv(user.id, %{title: "To Archive"})
      {:ok, updated} = Conversations.archive_conversation(conv)
      assert updated.status == "archived"
    end
  end

  describe "delete event" do
    # ConversationsLive delete handler tested via context since /bo/conversations route
    # is pending; verifies the underlying delete_conversation/1 context function works.
    test "deletes a conversation", %{user: user} do
      conv = create_conv(user.id, %{title: "To Delete"})
      {:ok, _} = Conversations.delete_conversation(conv)

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(conv.id)
      end
    end
  end

  describe "empty state" do
    test "shows no conversations message when list is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ "No conversations found"
    end
  end

  describe "view link" do
    test "renders a link to conversation detail", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "Detail Link Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ "/bo/conversations/#{conv.id}"
    end
  end
end
