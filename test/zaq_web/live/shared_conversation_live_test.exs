defmodule ZaqWeb.Live.SharedConversationLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Conversations

  defp create_shared_conversation do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "u_#{System.unique_integer([:positive])}",
        title: "Shared Test Conv"
      })

    {:ok, _} = Conversations.add_message(conv, %{role: "user", content: "Hello from user"})

    {:ok, _} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "Hello from assistant.",
        model: "gpt-4",
        confidence_score: 0.85
      })

    {:ok, share} = Conversations.share_conversation(conv, %{permission: "read"})

    {conv, share}
  end

  describe "mount" do
    test "renders shared conversation with messages", %{conn: conn} do
      {_conv, share} = create_shared_conversation()

      {:ok, _view, html} = live(conn, ~p"/s/#{share.share_token}")

      assert html =~ "Shared Conversation"
      assert html =~ "Shared Test Conv"
      assert html =~ "Hello from user"
      assert html =~ "Hello from assistant."
    end

    test "redirects for invalid token", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/s/bogus-token-value")

      assert path == "/"
    end

    test "is accessible without authentication", %{conn: conn} do
      {_conv, share} = create_shared_conversation()

      {:ok, _view, html} = live(conn, ~p"/s/#{share.share_token}")

      assert html =~ "Shared Test Conv"
    end

    test "redirects after share is revoked", %{conn: conn} do
      {_conv, share} = create_shared_conversation()

      {:ok, _view, _html} = live(conn, ~p"/s/#{share.share_token}")

      Conversations.revoke_share(share)

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/s/#{share.share_token}")
      assert path == "/"
    end
  end

  describe "read-only view" do
    test "does not show rating buttons", %{conn: conn} do
      {_conv, share} = create_shared_conversation()

      {:ok, view, _html} = live(conn, ~p"/s/#{share.share_token}")

      refute has_element?(view, "button[phx-click='rate_message']")
    end

    test "does not show share button", %{conn: conn} do
      {_conv, share} = create_shared_conversation()

      {:ok, view, _html} = live(conn, ~p"/s/#{share.share_token}")

      refute has_element?(view, "button", "Share")
    end
  end
end
