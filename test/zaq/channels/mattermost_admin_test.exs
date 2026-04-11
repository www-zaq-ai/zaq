defmodule Zaq.Channels.MattermostAdminTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.MattermostAdmin
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

  describe "fetch_bot_user_id/2" do
    test "returns bot id on HTTP 200" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/users/me"
            {200, %{"id" => "bot-user-1"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, "bot-user-1"} = MattermostAdmin.fetch_bot_user_id(url, "token-1")
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

      assert {:error, "HTTP 401"} = MattermostAdmin.fetch_bot_user_id(url, "token-1")
    end

    test "returns inspected reason on transport error" do
      url = unavailable_local_url()

      assert {:error, reason} = MattermostAdmin.fetch_bot_user_id(url, "token-1")
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

  describe "list_public_channels/2" do
    test "atomizes channel maps on success" do
      {child_spec, url} =
        OpenAIStub.server(
          fn conn, _body ->
            assert conn.request_path == "/v1/api/v4/teams/team-1/channels"
            {200, [%{"id" => "chan-1", "name" => "general"}]}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:ok, [channel]} =
               MattermostAdmin.list_public_channels(%{url: url, token: "token-1"}, "team-1")

      assert channel.id == "chan-1"
      assert channel.name == "general"
      refute Map.has_key?(channel, "name")
    end

    test "passes through ReqClient errors" do
      {child_spec, url} =
        OpenAIStub.server(
          fn _conn, _body ->
            {404, %{"error" => "temporary"}}
          end,
          self()
        )

      start_supervised!(child_spec)

      assert {:error, {404, %{"error" => "temporary"}}} =
               MattermostAdmin.list_public_channels(%{url: url, token: "token-1"}, "team-1")
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
