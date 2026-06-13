defmodule ZaqWeb.Live.BO.Communication.ConversationDetailLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Conversations
  alias ZaqWeb.Helpers.DateFormat

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
        content: "**ZAQ** is an AI company brain. [1]",
        model: "gpt-4",
        confidence_score: 0.9,
        sources: [%{"index" => 1, "path" => "guide.md"}],
        latency_ms: 120,
        trace: [
          %{
            "id" => "call-a",
            "type" => "tool_call",
            "name" => "read_file",
            "started_at" => "2026-05-02T10:00:00Z",
            "arguments" => %{"path" => "guide.md"},
            "response" => %{"ok" => true},
            "duration_ms" => 35
          },
          %{
            "id" => "call-b",
            "type" => "tool_call",
            "name" => "search_code",
            "started_at" => "2026-05-02T10:00:01Z",
            "arguments" => %{"query" => "ZAQ"},
            "response" => %{"matches" => 3},
            "duration_ms" => 85
          }
        ],
        metadata: %{
          "agent" => %{"name" => "Answering"},
          "measurements" => %{"latency_ms" => 120}
        }
      })

    {conv, assistant_msg}
  end

  describe "mount" do
    test "renders conversation thread", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/conversations/#{conv.id}")
      assert html =~ "What is ZAQ?"
      assert html =~ "ZAQ"
      assert html =~ "[1] guide.md"
    end

    test "shows back link", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/conversations/#{conv.id}")
      assert html =~ "History"
    end

    test "date separator is rendered for messages from today", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, _view, html} = live(conn, ~p"/bo/conversations/#{conv.id}")
      today_label = DateFormat.format_date(Date.utc_today())
      assert html =~ today_label
    end

    test "redirects on unknown conversation id", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} =
        live(conn, ~p"/bo/conversations/#{Ecto.UUID.generate()}")

      assert path =~ "/bo/"
    end
  end

  describe "assistant actions" do
    test "pushes clipboard event when copying a message", %{conn: conn, user: user} do
      {conv, _assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      render_hook(view, "copy_message", %{"text" => "Copy me"})

      assert_push_event(view, "clipboard", %{text: "Copy me"})
    end

    test "records positive feedback for an assistant message", %{conn: conn, user: user} do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element("button[phx-value-id='#{assistant_msg.id}'][phx-value-type='positive']")
      |> render_click()

      rating = Conversations.get_rating(assistant_msg, %{user_id: user.id})
      assert rating.rating == 5
    end

    test "opens and submits negative feedback modal", %{conn: conn, user: user} do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element("button[phx-value-id='#{assistant_msg.id}'][phx-value-type='negative']")
      |> render_click()

      assert has_element?(view, "#feedback-modal")

      view
      |> element("button[phx-click='toggle_feedback_reason'][phx-value-reason='Not accurate']")
      |> render_click()

      view
      |> element("textarea[name='comment']")
      |> render_change(%{"comment" => "Missing context"})

      view
      |> element("button[phx-click='submit_feedback']")
      |> render_click()

      refute has_element?(view, "#feedback-modal")

      rating = Conversations.get_rating(assistant_msg, %{user_id: user.id})
      assert rating.rating == 1
      assert rating.comment =~ "Not accurate"
      assert rating.comment =~ "Missing context"
    end

    test "closes negative feedback modal when cancel is clicked", %{conn: conn, user: user} do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element("button[phx-value-id='#{assistant_msg.id}'][phx-value-type='negative']")
      |> render_click()

      assert has_element?(view, "#feedback-modal")

      view
      |> element("#feedback-modal button", "Cancel")
      |> render_click()

      refute has_element?(view, "#feedback-modal")
    end
  end

  describe "share management" do
    test "opens share dialog", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      html = view |> element("button", "Share") |> render_click()
      assert html =~ "Share Conversation"
    end

    test "closes share dialog without creating a share", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view |> element("button", "Share") |> render_click()

      assert render(view) =~ "Share Conversation"

      view
      |> element("button[phx-click='close_share_dialog']", "Cancel")
      |> render_click()

      refute render(view) =~ "Share Conversation"
      assert Conversations.list_shares(conv) == []
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

    test "revoke_share no-ops when share does not exist", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      render_hook(view, "revoke_share", %{"id" => "missing-share-id"})

      assert Conversations.list_shares(conv) == []
    end
  end

  describe "misc events" do
    test "noop event leaves the view responsive", %{conn: conn, user: user} do
      {conv, _} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      render_hook(view, "noop", %{})

      assert has_element?(view, "a", "History")
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

    test "closes preview modal from shared source chip", %{conn: conn, user: user} do
      {conv, _assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element(~s(button[data-testid="source-chip"]))
      |> render_click()

      assert has_element?(view, "#file-preview-modal")

      view
      |> element("#file-preview-modal button[title='Close']")
      |> render_click()

      refute has_element?(view, "#file-preview-modal")
    end
  end

  describe "message info popin" do
    test "shows info icon, opens popin, sorts traces, and expands details", %{
      conn: conn,
      user: user
    } do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      assert has_element?(view, ~s([data-testid="message-info-#{assistant_msg.id}"]))

      view
      |> element(~s([data-testid="message-info-#{assistant_msg.id}"]))
      |> render_click()

      assert has_element?(view, ~s([data-testid="message-info-popin"]))

      html = render(view)
      assert String.contains?(html, "Search Code")
      assert String.contains?(html, "Read File")

      {search_idx, _} = :binary.match(html, "Search Code")
      {read_idx, _} = :binary.match(html, "Read File")
      assert read_idx < search_idx

      view
      |> element(~s([data-testid="trace-row-call-b"]))
      |> render_click()

      details = render(view)
      assert details =~ "Full JSON"
      assert details =~ "search_code"
      assert details =~ "85 ms"
    end

    test "closes message info popin from the close control", %{conn: conn, user: user} do
      {conv, assistant_msg} = create_conv_with_messages(user.id)
      {:ok, view, _html} = live(conn, ~p"/bo/conversations/#{conv.id}")

      view
      |> element(~s([data-testid="message-info-#{assistant_msg.id}"]))
      |> render_click()

      assert has_element?(view, ~s([data-testid="message-info-popin"]))

      view
      |> element(~s([data-testid="message-info-popin"] [phx-click="close_message_info_modal"]))
      |> render_click()

      refute has_element?(view, ~s([data-testid="message-info-popin"]))
    end
  end
end
