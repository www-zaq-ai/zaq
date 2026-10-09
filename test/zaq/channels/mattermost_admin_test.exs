defmodule Zaq.Channels.MattermostAdminTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.MattermostAdmin
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

  describe "history capabilities" do
    test "uses one identifier contract for advertisement and retrieval" do
      config = %{url: "https://example.invalid", token: "token"}
      valid = "abcde12345abcde12345abcde1"

      assert {:ok, %{members: true}} =
               MattermostAdmin.room_capabilities(config, valid)

      assert {:ok, %{members: false}} =
               MattermostAdmin.room_capabilities(config, "invalid")

      assert {:error, :invalid_channel_id} =
               MattermostAdmin.room_members(config, "invalid")
    end
  end

  describe "fetch_room_message/3" do
    test "returns unavailable for a non-binary message id without making a request" do
      config = %{url: "https://example.invalid", token: "test-token"}
      channel_id = "abcde12345abcde12345abcde1"

      assert {:error, :unavailable} =
               MattermostAdmin.fetch_room_message(config, channel_id, nil)

      refute_receive {:openai_request, _, _, _, _}
    end

    test "returns a root post with nil timestamp when the millisecond value is out of range" do
      channel_id = "abcde12345abcde12345abcde1"
      assert {:error, :invalid_unix_time} = DateTime.from_unix(10 ** 30, :millisecond)

      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.method == "GET"
            assert conn.request_path == "/v1/api/v4/posts/root-1"

            {200,
             %{
               "id" => "root-1",
               "channel_id" => channel_id,
               "root_id" => "",
               "user_id" => "human-1",
               "message" => "root",
               "create_at" => 10 ** 30
             }}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok,
              %{
                author_id: "human-1",
                content: "root",
                role: "external",
                inserted_at: nil,
                attachments: []
              }} =
               MattermostAdmin.fetch_room_message(
                 %{
                   url: url,
                   token: "test-token",
                   settings: %{"jido_chat" => %{"bot_user_id" => "bot-1"}}
                 },
                 channel_id,
                 "root-1"
               )

      assert_receive {:openai_request, "GET", "/v1/api/v4/posts/root-1", "", _}
    end

    test "returns a root post with nil timestamp when create_at is not an integer" do
      channel_id = "abcde12345abcde12345abcde1"

      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.method == "GET"
            assert conn.request_path == "/v1/api/v4/posts/root-1"

            {200,
             %{
               "id" => "root-1",
               "channel_id" => channel_id,
               "root_id" => "",
               "user_id" => "human-1",
               "message" => "root",
               "create_at" => "not-a-millisecond"
             }}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok,
              %{
                author_id: "human-1",
                content: "root",
                role: "external",
                inserted_at: nil,
                attachments: []
              }} =
               MattermostAdmin.fetch_room_message(
                 %{
                   url: url,
                   token: "test-token",
                   settings: %{"jido_chat" => %{"bot_user_id" => "bot-1"}}
                 },
                 channel_id,
                 "root-1"
               )

      assert_receive {:openai_request, "GET", "/v1/api/v4/posts/root-1", "", _}
    end
  end

  describe "fetch_bot_user_id/2" do
    test "returns bot id and preserves identity errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.method == "GET"
            assert conn.request_path == "/v1/api/v4/users/me"
            {200, %{"id" => "bot-user-1", "username" => "zaq-local"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, "bot-user-1"} = MattermostAdmin.fetch_bot_user_id(url, "token-1")
      assert_receive {:openai_request, "GET", "/v1/api/v4/users/me", "", _}

      {error_child_spec, error_url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/me"
            {200, %{"id" => "bot-user-1"}}
          end,
          self()
        )

      start_supervised!(error_child_spec)

      assert {:error, :invalid_identity} = MattermostAdmin.fetch_bot_user_id(error_url, "token-1")
      assert_receive {:openai_request, "GET", "/v1/api/v4/users/me", "", _}
    end
  end

  describe "channel_membership_snapshot/3" do
    test "rejects invalid arguments before attempting pagination" do
      channel_id = "abcde12345abcde12345abcde1"
      fetch_page = fn _, _, _, _ -> flunk("invalid channel IDs must not fetch a page") end

      assert {:error, :invalid_channel_id} =
               MattermostAdmin.channel_membership_snapshot(%{}, channel_id, %{
                 fetch_page: fetch_page
               })

      assert {:error, :invalid_channel_id} =
               MattermostAdmin.channel_membership_snapshot(%{}, nil, [])
    end

    test "fetches the first membership page from Mattermost by default" do
      channel_id = "abcde12345abcde12345abcde1"
      members_path = "/v1/api/v4/channels/#{channel_id}/members"

      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.method == "GET"
            assert conn.request_path == members_path

            {200, [%{"user_id" => "member-1"}]}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, %{complete: true, member_ids: ["member-1"]}} =
               MattermostAdmin.channel_membership_snapshot(
                 %{url: url, token: "test-token"},
                 channel_id
               )

      assert_receive {:openai_request, "GET", ^members_path, query, _}
      assert URI.decode_query(query) == %{"page" => "0", "per_page" => "200"}
    end
  end

  describe "fetch_bot_identity/2" do
    test "returns bot id and username on HTTP 200" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/me"
            {200, %{"id" => "bot-user-1", "username" => "zaq-local", "nickname" => "Zaq Local"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, %{id: "bot-user-1", username: "zaq-local"}} =
               MattermostAdmin.fetch_bot_identity(url, "token-1")
    end

    test "rejects incomplete identity responses" do
      {child_spec, url} =
        OpenAIStub.server(fn _conn, _body -> {200, %{"id" => "bot-user-1"}} end, self())

      start_supervised!(child_spec)

      assert {:error, :invalid_identity} = MattermostAdmin.fetch_bot_identity(url, "token-1")
    end

    test "returns formatted HTTP error on non-200" do
      {child_spec, url} =
        OpenAIStub.server(
          fn _conn, _body ->
            {401, %{"error" => "unauthorized"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:error, "HTTP 401"} = MattermostAdmin.fetch_bot_identity(url, "token-1")
    end

    test "returns inspected reason on transport error" do
      url = unavailable_local_url()

      assert {:error, reason} = MattermostAdmin.fetch_bot_identity(url, "token-1")
      assert is_binary(reason)
    end
  end

  describe "send_message/2" do
    test "returns config-missing error when mattermost is not configured" do
      assert {:error, :mattermost_not_configured} =
               MattermostAdmin.send_message("chan-1", "hello")
    end

    test "passes through ReqClient success" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, body ->
            assert conn.method == "POST"
            assert conn.request_path == "/v1/api/v4/posts"

            decoded = Jason.decode!(body)
            assert decoded["channel_id"] == "chan-1"
            assert decoded["message"] == "hello"

            {201, %{"id" => "post-1"}}
          end,
          self()
        )

      start_supervised!(child_spec)
      insert_mattermost_config(url)

      assert {:ok, %{"id" => "post-1"}} = MattermostAdmin.send_message("chan-1", "hello")
    end
  end

  describe "list_teams/1" do
    test "atomizes team maps on success" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/me/teams"
            {200, [%{"id" => "team-1", "display_name" => "Core"}]}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, [team]} = MattermostAdmin.list_teams(%{url: url, token: "token-1"})
      assert team.id == "team-1"
      assert team.display_name == "Core"
      refute Map.has_key?(team, "id")
    end

    test "passes through ReqClient errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn _conn, _body ->
            {404, %{"error" => "boom"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:error, {404, %{"error" => "boom"}}} =
               MattermostAdmin.list_teams(%{url: url, token: "token-1"})
    end
  end

  describe "list_accessible_channels/2" do
    test "atomizes public and private channel maps visible to the bot" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/me/teams/team-1/channels"

            {200,
             [
               %{"id" => "public-1", "name" => "general", "type" => "O"},
               %{"id" => "private-1", "name" => "security", "type" => "P"}
             ]}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, [public, private]} =
               MattermostAdmin.list_accessible_channels(%{url: url, token: "token-1"}, "team-1")

      assert public.id == "public-1"
      assert public.type == "O"
      assert private.id == "private-1"
      assert private.type == "P"
    end

    test "passes through ReqClient errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn _conn, _body ->
            {403, %{"error" => "forbidden"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:error, {403, %{"error" => "forbidden"}}} =
               MattermostAdmin.list_accessible_channels(%{url: url, token: "token-1"}, "team-1")
    end
  end

  describe "fetch_user/2" do
    test "atomizes user map on success" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/user-1"
            {200, %{"id" => "user-1", "username" => "ada", "first_name" => "Ada"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, user} = MattermostAdmin.fetch_user(%{url: url, token: "token-1"}, "user-1")
      assert user.id == "user-1"
      assert user.username == "ada"
      refute Map.has_key?(user, "id")
    end

    test "passes through HTTP errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn _conn, _body ->
            {404, %{"error" => "not found"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:error, {404, %{"error" => "not found"}}} =
               MattermostAdmin.fetch_user(%{url: url, token: "token-1"}, "user-1")
    end
  end

  describe "clear_channel/1" do
    test "returns config-missing error when mattermost is not configured" do
      assert {:error, :mattermost_not_configured} = MattermostAdmin.clear_channel("chan-1")
    end

    test "passes through fetch_posts errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            if conn.method == "GET" and conn.request_path == "/v1/api/v4/channels/chan-1/posts" do
              {404, %{"error" => "fetch-failed"}}
            else
              {404, %{"error" => "unexpected"}}
            end
          end,
          self()
        )

      start_supervised!(child_spec)
      insert_mattermost_config(url)

      assert {:error, {404, %{"error" => "fetch-failed"}}} =
               MattermostAdmin.clear_channel("chan-1")
    end

    test "deletes returned posts and returns deleted count" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            case {conn.method, conn.request_path} do
              {"GET", "/v1/api/v4/channels/chan-1/posts"} ->
                {200, %{"posts" => %{"post-a" => %{}, "post-b" => %{}}}}

              {"DELETE", "/v1/api/v4/posts/post-a"} ->
                {200, %{}}

              {"DELETE", "/v1/api/v4/posts/post-b"} ->
                {200, %{}}

              _ ->
                {404, %{"error" => "unexpected"}}
            end
          end,
          self()
        )

      start_supervised!(child_spec)
      insert_mattermost_config(url)

      assert {:ok, 2} = MattermostAdmin.clear_channel("chan-1")

      assert_receive {:openai_request, "GET", "/v1/api/v4/channels/chan-1/posts", _, _}
      assert_receive {:openai_request, "DELETE", delete_path_1, _, _}
      assert_receive {:openai_request, "DELETE", delete_path_2, _, _}

      assert Enum.sort([delete_path_1, delete_path_2]) ==
               Enum.sort(["/v1/api/v4/posts/post-a", "/v1/api/v4/posts/post-b"])
    end

    test "returns zero when there are no posts to delete" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            case {conn.method, conn.request_path} do
              {"GET", "/v1/api/v4/channels/chan-1/posts"} ->
                {200, %{"posts" => %{}}}

              _ ->
                {404, %{"error" => "unexpected"}}
            end
          end,
          self()
        )

      start_supervised!(child_spec)
      insert_mattermost_config(url)

      assert {:ok, 0} = MattermostAdmin.clear_channel("chan-1")

      assert_receive {:openai_request, "GET", "/v1/api/v4/channels/chan-1/posts", _, _}
      refute_receive {:openai_request, "DELETE", _, _, _}
    end
  end

  defp insert_mattermost_config(url) do
    unique = System.unique_integer([:positive])

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Mattermost #{unique}",
      provider: "mattermost",
      kind: "retrieval",
      url: url,
      token: "token-#{unique}",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp unavailable_local_url do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}"
  end
end
