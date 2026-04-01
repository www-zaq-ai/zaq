defmodule ZaqWeb.Live.BO.Communication.ConversationDetailLiveTest do
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

  defp create_conv_with_messages(user_id) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "u_#{System.unique_integer([:positive])}",
        user_id: user_id,
        title: "Test Detail Conv"
      })

    {:ok, _user_msg} = Conversations.add_message(conv, %{role: "user", content: "What is ZAQ?"})

    {:ok, assistant_msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "ZAQ is an AI company brain.",
        model: "gpt-4",
        confidence_score: 0.9,
        sources: [%{"path" => "guide.md"}]
      })

    {conv, assistant_msg}
  end

  describe "mount" do
    test "renders conversation thread", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/conversations/#{conv.id}")
      assert html =~ "What is ZAQ?"
      assert html =~ "ZAQ is an AI company brain."
    end

    test "shows back link", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/conversations/#{conv.id}")
      assert html =~ "History"
    end

    test "redirects on unknown conversation id", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} =
        live(conn, ~p"/bo/conversations/#{Ecto.UUID.generate()}")

      assert path =~ "/bo/"
    end
  end

  describe "rate_message" do
    test "rates an assistant message", %{conn: conn, user: user} do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element("button[phx-value-id='#{assistant_msg.id}'][phx-value-rating='5']")
      |> render_click()

      rating = Conversations.get_rating(assistant_msg, %{user_id: user.id})
      assert rating.rating == 5
    end
  end

  describe "share management" do
    test "opens share dialog", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      html = view |> element("button", "Share") |> render_click()
      assert html =~ "Share Conversation"
    end

    test "creates a share and shows link with copy button", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view |> element("button", "Share") |> render_click()

      html =
        view
        |> element("form[phx-submit='share']")
        |> render_submit(%{"permission" => "read"})

      shares = Conversations.list_shares(conv)
      assert length(shares) == 1

      share = hd(shares)
      assert html =~ "/s/#{share.share_token}"
      assert has_element?(view, "#copy-#{share.id}")
      assert has_element?(view, "#copy-#{share.id}[phx-hook='CopyToClipboard']")
    end

    test "revokes a share", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, share} = Conversations.share_conversation(conv, %{permission: "read"})

      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element("#share-#{share.id} button", "Revoke")
      |> render_click()

      assert Conversations.list_shares(conv) == []
    end
  end

  describe "source preview" do
    test "opens preview modal from shared source chip", %{conn: conn, user: user} do
      {conv, _assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element(~s(button[data-testid="source-chip"]))
      |> render_click()

      assert has_element?(view, "#file-preview-modal")
      assert has_element?(view, "#file-preview-modal p", "File not found")
    end
  end
end
