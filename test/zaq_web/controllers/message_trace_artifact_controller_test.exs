defmodule ZaqWeb.MessageTraceArtifactControllerTest do
  use ZaqWeb.ConnCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo

  test "requires an authenticated BO session", %{conn: conn} do
    conn = get(conn, "/bo/trace-artifacts/#{Ecto.UUID.generate()}")
    assert redirected_to(conn) == "/bo/login"
  end

  test "serves an owned artifact with safe headers", %{conn: conn} do
    owner = authenticated_user("artifact_owner")
    artifact = artifact_fixture(owner, "image/svg+xml", "unsafe\"\r\nname.svg")

    conn =
      conn |> init_test_session(%{user_id: owner.id}) |> get("/bo/trace-artifacts/#{artifact.id}")

    assert response(conn, 200) == <<0, 1, 2, 3>>
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="unsafe_name.svg")
           ]

    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "does not reveal another user's artifact", %{conn: conn} do
    owner = authenticated_user("artifact_private_owner")
    other = authenticated_user("artifact_other_user")
    artifact = artifact_fixture(owner, "image/png", "private.png")

    conn =
      conn |> init_test_session(%{user_id: other.id}) |> get("/bo/trace-artifacts/#{artifact.id}")

    assert response(conn, 404) == "Artifact not found"
  end

  test "allows active conversation shares and rejects expired shares", %{conn: conn} do
    owner = authenticated_user("artifact_share_owner")
    active_user = authenticated_user("artifact_active_share")
    expired_user = authenticated_user("artifact_expired_share")
    artifact = artifact_fixture(owner, "image/png", "shared.png")
    message = Repo.get!(Zaq.Engine.Conversations.Message, artifact.message_id)
    conversation = Conversations.get_conversation!(message.conversation_id)

    assert {:ok, _share} =
             Conversations.share_conversation(conversation, %{
               shared_with_user_id: active_user.id,
               permission: "read",
               expires_at: DateTime.utc_now() |> DateTime.add(60, :second)
             })

    assert {:ok, _share} =
             Conversations.share_conversation(conversation, %{
               shared_with_user_id: expired_user.id,
               permission: "read",
               expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
             })

    active_conn =
      conn
      |> recycle()
      |> init_test_session(%{user_id: active_user.id})
      |> get("/bo/trace-artifacts/#{artifact.id}")

    assert response(active_conn, 200) == <<0, 1, 2, 3>>

    expired_conn =
      conn
      |> recycle()
      |> init_test_session(%{user_id: expired_user.id})
      |> get("/bo/trace-artifacts/#{artifact.id}")

    assert response(expired_conn, 404) == "Artifact not found"
  end

  test "allows super admins to inspect artifacts", %{conn: conn} do
    owner = authenticated_user("artifact_admin_owner")
    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
    artifact = artifact_fixture(owner, "image/png", "diagram.png")

    conn =
      conn |> init_test_session(%{user_id: admin.id}) |> get("/bo/trace-artifacts/#{artifact.id}")

    assert response(conn, 200) == <<0, 1, 2, 3>>
    assert List.first(get_resp_header(conn, "content-type")) =~ "image/png"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="diagram.png")]
  end

  defp authenticated_user(username) do
    user = user_fixture(%{username: username})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    user
  end

  defp artifact_fixture(owner, mime_type, name) do
    {:ok, conversation} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "bo_user_#{owner.id}",
        user_id: owner.id
      })

    incoming = %Incoming{
      content: "Inspect the attachment",
      channel_id: "bo",
      author_id: to_string(owner.id),
      provider: :web,
      metadata: %{conversation_id: conversation.id}
    }

    result = %{
      answer: "Done",
      trace: [%{"id" => "tool-media", "type" => "tool_call"}],
      trace_artifacts: [
        %{
          content: <<0, 1, 2, 3>>,
          name: name,
          mime_type: mime_type,
          record: %{"id" => "media-1"},
          tool_call_id: "tool-media",
          tool_name: "download_document"
        }
      ]
    }

    assert {:ok, _persisted} = Conversations.persist_from_incoming(incoming, result)
    Repo.one!(MessageTraceArtifact)
  end
end
