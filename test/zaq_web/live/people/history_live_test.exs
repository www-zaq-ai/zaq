defmodule ZaqWeb.Live.People.HistoryLiveTest do
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Repo

  test "persisted trace artifacts use People-only parent-scoped links and bytes", ctx do
    incoming = %Incoming{
      content: "Inspect",
      channel_id: "api",
      provider: "api",
      metadata: %{conversation_id: ctx.conv.id}
    }

    {:ok, saved} =
      Conversations.persist_from_incoming(incoming, %{
        answer: "Artifact response",
        trace: [%{"id" => "media", "type" => "tool_call"}],
        trace_artifacts: [
          %{
            tool_call_id: "media",
            tool_name: "download_document",
            content: "Proof",
            name: "proof.txt",
            mime_type: "text/plain",
            record: %{"attributes" => %{"source_type" => "communication_media"}}
          }
        ]
      })

    artifact = Repo.get_by!(MessageTraceArtifact, message_id: saved.assistant_message_id)
    {:ok, view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
    render_click(view, "open_message_info_modal", %{"id" => saved.assistant_message_id})
    render_click(view, "toggle_trace_details", %{"trace_id" => "media"})

    path =
      "/people/conversations/#{ctx.conv.id}/messages/#{saved.assistant_message_id}/artifacts/#{artifact.id}"

    assert has_element?(view, "a[data-testid=trace-artifact-link][href='#{path}']", "proof.txt")
    refute render(view) =~ "/bo/trace-artifacts"
    assert ctx.conn |> get(path) |> response(200) == "Proof"
    foreign_path = String.replace(path, ctx.conv.id, ctx.foreign.id)
    assert ctx.conn |> get(foreign_path) |> response(404) == "Resource not found"
  end

  test "local source types retain safe preview and download URLs", ctx do
    root = Path.join(System.tmp_dir!(), "people-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zaq, Zaq.Storage, previous),
        else: Application.delete_env(:zaq, Zaq.Storage)

      File.rm_rf!(root)
    end)

    for {name, bytes, selector} <- [
          {"source.txt", "Plain source", "pre"},
          {"source.pdf", "%PDF-1.4", "iframe"},
          {"source.png", <<137, 80, 78, 71>>, "img"},
          {"source.bin", <<0, 1, 2>>, "a[download]"}
        ] do
      File.write!(Path.join(root, name), bytes)
      {:ok, document} = Document.create(%{source: name})

      {:ok, _} =
        Permissions.grant({"document", to_string(document.id)}, %{
          person_id: ctx.person.id,
          access_rights: ["read"]
        })

      {:ok, _} =
        Conversations.add_message(ctx.conv, %{
          role: "assistant",
          content: "Source #{name}",
          sources: [%{"type" => "memory"}, %{"path" => name}]
        })

      {:ok, view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
      render_click(view, "open_preview_modal", %{"path" => name})
      assert has_element?(view, "#file-preview-modal #{selector}")
      refute render(view) =~ "/bo/"
    end
  end

  test "negative feedback, inspection and forged events keep a bounded current detail", ctx do
    {:ok, view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
    render_click(view, "feedback", %{"id" => ctx.message.id, "type" => "negative"})
    render_click(view, "toggle_feedback_reason", %{"reason" => "Not factually correct"})
    render_change(view, "update_feedback_comment", %{"comment" => "Please correct this"})
    render_submit(view, "submit_feedback", %{})
    rating = Conversations.get_rating(ctx.message, %{person_id: ctx.person.id})
    assert rating.rating == 1
    assert rating.comment == "Not factually correct\nPlease correct this"
    assert render(view) =~ "Please correct this"
    render_click(view, "feedback", %{"id" => ctx.message.id, "type" => "negative"})
    render_click(view, "toggle_feedback_reason", %{"reason" => "unknown reason"})
    render_click(view, "close_feedback_modal", %{})
    render_click(view, "feedback", %{"id" => Ecto.UUID.generate(), "type" => "negative"})
    render_click(view, "feedback", %{"id" => Ecto.UUID.generate(), "type" => "positive"})
    assert render(view) =~ "Unable to complete"
    render_click(view, "open_message_info_modal", %{"id" => ctx.message.id})
    assert has_element?(view, "[data-testid=message-info-popin]", "example")
    render_click(view, "toggle_trace_details", %{"trace_id" => "0"})
    render_click(view, "copy_message", %{"text" => "Owned answer"})
    assert_push_event(view, "clipboard", %{text: "Owned answer"})
    render_click(view, "close_message_info_modal", %{})
    refute has_element?(view, "[data-testid=message-info-popin]")
    render_click(view, "open_message_info_modal", %{"id" => "bad"})
    render_click(view, "open_preview_modal", %{"path" => "foreign.md"})
    assert render(view) =~ "Unable to complete"
    {:ok, _} = PeoplePermissions.grant(:all_people, :share_conversations)
    render_click(view, "open_share_dialog", %{})
    render_click(view, "close_share_dialog", %{})
    refute has_element?(view, "#conversation-share-dialog")
    render_submit(view, "share", %{"permission" => "write"})
    assert Conversations.list_shares(ctx.conv) == []
    render_click(view, "revoke_share", %{"id" => "bad"})

    render_submit(view, "share", %{"permission" => "read", "expires_at" => "2000-01-01T00:00:00Z"})

    [share] = Conversations.list_shares(ctx.conv)
    assert Conversations.get_conversation_by_token(share.share_token) == nil
    render_click(view, "revoke_share", %{"id" => share.id})
    assert Conversations.list_shares(ctx.conv) == []
  end

  test "list filter and page events preserve only local known query parameters", ctx do
    {:ok, _} =
      Conversations.create_conversation(%{
        person_id: ctx.person.id,
        title: "Archived owned",
        status: "archived",
        channel_type: "slack"
      })

    {:ok, view, _} = live(ctx.conn, "/people/history")

    render_change(view, "filter", %{
      "status" => "archived",
      "channel_type" => "slack",
      "person_id" => "foreign"
    })

    assert_patch(view, "/people/history?channel_type=slack&page=1&status=archived")
    assert render(view) =~ "Archived owned"
    refute render(view) =~ "Owned conversation"
    render_click(view, "change_page", %{"page" => "999"})
    assert_patch(view, "/people/history?channel_type=slack&page=999&status=archived")
    assert has_element?(view, "[data-testid=simple-pagination-range]", "1–1 of 1")
    render_click(view, "delete_conversation", %{"id" => ctx.conv.id})
    assert Conversations.get_conversation(ctx.conv.id)
  end

  test "source previews and byte routes enforce message parent and document permission", ctx do
    {:ok, document} =
      Document.create(%{source: "people-ui-citation.md", content: "Authorized citation"})

    {:ok, message} =
      Conversations.add_message(ctx.conv, %{
        role: "assistant",
        content: "See source",
        sources: [%{"path" => document.source}]
      })

    path =
      "/people/conversations/#{ctx.conv.id}/messages/#{message.id}/source?source=#{document.source}"

    assert ctx.conn |> get(path) |> response(404) == "Resource not found"
    {:ok, denied_view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
    render_click(denied_view, "open_preview_modal", %{"path" => document.source})
    refute has_element?(denied_view, "#file-preview-modal")
    assert render(denied_view) =~ "Unable to complete"

    {:ok, _} =
      Permissions.grant({"document", to_string(document.id)}, %{
        person_id: ctx.person.id,
        access_rights: ["read"]
      })

    response = get(ctx.conn, path)
    assert response(response, 200) == "Authorized citation"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "content-security-policy") == ["sandbox"]
    {:ok, view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
    render_click(view, "open_preview_modal", %{"path" => document.source})
    assert has_element?(view, "#file-preview-modal", "Authorized citation")
    refute render(view) =~ "/bo/"
    render_click(view, "close_preview_modal", %{})
    refute has_element?(view, "#file-preview-modal")
    {:ok, _} = PeopleAuth.revoke_session(ctx.token)
    assert get(ctx.conn, path) |> redirected_to() == "/people/login"
  end

  setup %{conn: conn} do
    {:ok, person} = People.create_person(%{full_name: "History Reader"})
    {:ok, other} = People.create_person(%{full_name: "Other"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_message_history)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 9, 7, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

    {:ok, conv} =
      Conversations.create_conversation(%{
        person_id: person.id,
        title: "Owned conversation",
        channel_type: "api"
      })

    {:ok, foreign} =
      Conversations.create_conversation(%{
        person_id: other.id,
        title: "Foreign secret",
        channel_type: "api"
      })

    {:ok, msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "Owned answer",
        model: "example"
      })

    %{
      conn: init_test_session(conn, %{person_session_token: token}),
      person: person,
      token: token,
      conv: conv,
      foreign: foreign,
      message: msg
    }
  end

  test "shared header/settings appear on profile history and detail with scoped navigation",
       ctx do
    for route <- ["/people/profile", "/people/history", "/people/conversations/#{ctx.conv.id}"] do
      {:ok, view, html} = live(ctx.conn, route)
      assert has_element?(view, "#people-header")
      assert has_element?(view, "#people-profile-menu", "History Reader")

      assert has_element?(
               view,
               "#people-settings-menu a[href='/people/history']",
               "Conversations"
             )

      refute html =~ ctx.token
      refute html =~ "/bo/"
      refute html =~ "Foreign secret"
      refute html =~ "delete_conversation"
    end
  end

  test "detail rates only owned message and sharing is separately guarded", ctx do
    {:ok, view, _} = live(ctx.conn, "/people/conversations/#{ctx.conv.id}")
    refute has_element?(view, "button[phx-click=open_share_dialog]")
    render_click(view, "open_share_dialog", %{})
    refute has_element?(view, "#conversation-share-dialog")
    render_click(view, "feedback", %{"id" => ctx.message.id, "type" => "positive"})
    assert Conversations.get_rating(ctx.message, %{person_id: ctx.person.id}).rating == 5
    render_click(view, "delete_conversation", %{"id" => ctx.conv.id})
    assert Conversations.get_conversation(ctx.conv.id)
    {:ok, _} = PeoplePermissions.grant(:all_people, :share_conversations)
    render_click(view, "open_share_dialog", %{})
    assert has_element?(view, "#conversation-share-dialog")
    view |> form("#conversation-share-form", permission: "read") |> render_submit()
    assert [_] = Conversations.list_shares(ctx.conv)
    assert has_element?(view, "[data-share-url]")
  end

  test "direct foreign/malformed detail never reveals content and revocation removes history",
       ctx do
    for id <- [ctx.foreign.id, "malformed"] do
      assert {:error, {:redirect, %{to: "/people/history"}}} =
               live(ctx.conn, "/people/conversations/#{id}")
    end

    {:ok, view, _} = live(ctx.conn, "/people/history")
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_message_history)
    render_click(view, "change_page", %{"page" => "2"})
    assert_redirect(view, "/people/profile")
  end
end
