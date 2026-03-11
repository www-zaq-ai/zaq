defmodule Zaq.Channels.Retrieval.Mattermost.APITest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Retrieval.Mattermost.API
  alias Zaq.Repo

  defmodule StubPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      send(
        opts[:test_pid],
        {:stub_request, conn.method, conn.request_path, conn.query_string, body}
      )

      case opts[:handler].(conn, body) do
        {status, response} when is_map(response) or is_list(response) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))

        {status, response} ->
          send_resp(conn, status, response)
      end
    end
  end

  test "send_message/4 posts JSON payload" do
    base_url =
      start_stub_server(fn conn, body ->
        assert conn.request_path == "/api/v4/posts"
        assert conn.method == "POST"

        assert %{"channel_id" => "channel-1", "message" => "hello"} = Jason.decode!(body)

        {201, %{"id" => "post-1", "ok" => true}}
      end)

    config = %ChannelConfig{url: base_url, token: "token"}

    assert {:ok, %{"id" => "post-1", "ok" => true}} =
             API.send_message(config, "channel-1", "hello", nil)
  end

  test "send_message/4 includes root_id when thread is present" do
    base_url =
      start_stub_server(fn _conn, body ->
        assert %{"channel_id" => "channel-1", "message" => "hello", "root_id" => "thread-1"} =
                 Jason.decode!(body)

        {201, %{"id" => "post-2"}}
      end)

    config = %ChannelConfig{url: base_url, token: "token"}

    assert {:ok, %{"id" => "post-2"}} =
             API.send_message(config, "channel-1", "hello", "thread-1")
  end

  test "get_bot_user/1 returns compact user map" do
    base_url =
      start_stub_server(fn conn, _body ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v4/users/me"
        {200, %{"id" => "bot-1", "username" => "zaq-bot", "email" => "ignored@example.com"}}
      end)

    assert {:ok, %{id: "bot-1", username: "zaq-bot"}} =
             API.get_bot_user(%ChannelConfig{url: base_url, token: "token"})
  end

  test "list_teams/1 maps teams" do
    base_url =
      start_stub_server(fn conn, _body ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v4/users/me/teams"

        {200,
         [
           %{"id" => "t2", "display_name" => "Zulu", "name" => "zulu"},
           %{"id" => "t1", "display_name" => "Alpha", "name" => "alpha"}
         ]}
      end)

    assert {:ok, teams} = API.list_teams(%ChannelConfig{url: base_url, token: "token"})

    assert teams == [
             %{id: "t2", display_name: "Zulu", name: "zulu"},
             %{id: "t1", display_name: "Alpha", name: "alpha"}
           ]
  end

  test "list_public_channels/3 filters private channels and sorts by display name" do
    base_url =
      start_stub_server(fn conn, _body ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v4/teams/team-1/channels"
        assert conn.query_string == "page=1&per_page=2"

        {200,
         [
           %{"id" => "c2", "display_name" => "Zulu", "name" => "zulu", "type" => "O"},
           %{"id" => "c3", "display_name" => "Private", "name" => "private", "type" => "P"},
           %{"id" => "c1", "display_name" => "Alpha", "name" => "alpha", "type" => "O"}
         ]}
      end)

    assert {:ok, channels} =
             API.list_public_channels(%ChannelConfig{url: base_url, token: "token"}, "team-1",
               page: 1,
               per_page: 2
             )

    assert channels == [
             %{
               id: "c1",
               display_name: "Alpha",
               name: "alpha",
               type: "O",
               header: nil,
               purpose: nil
             },
             %{id: "c2", display_name: "Zulu", name: "zulu", type: "O", header: nil, purpose: nil}
           ]
  end

  test "clear_channel/1 deletes all posts from configured mattermost channel" do
    parent = self()

    base_url =
      start_stub_server(fn conn, _body ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/channels/channel-1/posts"} ->
            {200, %{"order" => ["post-1", "post-2"]}}

          {"DELETE", "/api/v4/posts/post-1"} ->
            send(parent, :deleted_post_1)
            {200, ""}

          {"DELETE", "/api/v4/posts/post-2"} ->
            send(parent, :deleted_post_2)
            {200, ""}
        end
      end)

    insert_mattermost_config(url: base_url)

    assert :ok = API.clear_channel("channel-1")
    assert_receive :deleted_post_1
    assert_receive :deleted_post_2
  end

  test "clear_channel/1 returns not configured error" do
    assert {:error, :mattermost_not_configured} = API.clear_channel("channel-1")
  end

  test "send_message/4 returns status errors from API" do
    base_url =
      start_stub_server(fn _conn, _body ->
        {400, "bad request"}
      end)

    config = %ChannelConfig{url: base_url, token: "token"}

    assert {:error, %{status: 400, body: "bad request"}} =
             API.send_message(config, "channel-1", "hello", nil)
  end

  test "send_message/4 returns transport errors" do
    config = %ChannelConfig{url: "http://127.0.0.1:1", token: "token"}

    assert {:error, reason} = API.send_message(config, "channel-1", "hello", nil)
    assert is_atom(reason)
  end

  test "send_message/3 returns configured error when no config exists" do
    assert {:error, :mattermost_not_configured} = API.send_message("channel-1", "hello")
  end

  test "send_message/3 uses configured channel config from DB" do
    base_url =
      start_stub_server(fn conn, body ->
        assert conn.request_path == "/api/v4/posts"
        assert conn.method == "POST"
        assert %{"channel_id" => "channel-1", "message" => "hello from db"} = Jason.decode!(body)
        {201, %{"id" => "post-db"}}
      end)

    insert_mattermost_config(url: base_url)

    assert {:ok, %{"id" => "post-db"}} = API.send_message("channel-1", "hello from db")
  end

  test "send_message/4 does not include root_id when thread id is empty string" do
    base_url =
      start_stub_server(fn _conn, body ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "root_id")
        {201, %{"id" => "post-no-root"}}
      end)

    config = %ChannelConfig{url: base_url, token: "token"}

    assert {:ok, %{"id" => "post-no-root"}} =
             API.send_message(config, "channel-1", "hello", "")
  end

  test "get_bot_user/1 returns non-200 status" do
    base_url =
      start_stub_server(fn _conn, _body ->
        {403, "forbidden"}
      end)

    assert {:error, %{status: 403, body: "forbidden"}} =
             API.get_bot_user(%ChannelConfig{url: base_url, token: "token"})
  end

  test "get_bot_user/1 returns transport errors" do
    assert {:error, reason} =
             API.get_bot_user(%ChannelConfig{url: "http://127.0.0.1:1", token: "token"})

    assert is_atom(reason)
  end

  test "list_teams/1 returns non-200 status" do
    base_url =
      start_stub_server(fn _conn, _body ->
        {500, "oops"}
      end)

    assert {:error, %{status: 500, body: "oops"}} =
             API.list_teams(%ChannelConfig{url: base_url, token: "token"})
  end

  test "list_public_channels/3 returns non-200 status" do
    base_url =
      start_stub_server(fn _conn, _body ->
        {502, "gateway"}
      end)

    assert {:error, %{status: 502, body: "gateway"}} =
             API.list_public_channels(%ChannelConfig{url: base_url, token: "token"}, "team-1")
  end

  test "clear_channel/1 returns list error" do
    base_url =
      start_stub_server(fn _conn, _body ->
        {500, "cannot list"}
      end)

    insert_mattermost_config(url: base_url)

    assert {:error, %{status: 500, body: "cannot list"}} = API.clear_channel("channel-1")
  end

  test "clear_channel/1 keeps going when one delete fails" do
    parent = self()

    base_url =
      start_stub_server(fn conn, _body ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/channels/channel-1/posts"} ->
            {200, %{"order" => ["post-1", "post-2"]}}

          {"DELETE", "/api/v4/posts/post-1"} ->
            send(parent, :delete_failed_post_1)
            {500, "failed"}

          {"DELETE", "/api/v4/posts/post-2"} ->
            send(parent, :delete_ok_post_2)
            {200, ""}
        end
      end)

    insert_mattermost_config(url: base_url)

    assert :ok = API.clear_channel("channel-1")
    assert_receive :delete_failed_post_1
    assert_receive :delete_ok_post_2
  end

  defp insert_mattermost_config(attrs) do
    defaults = %{
      name: "Mattermost",
      provider: "mattermost",
      kind: "retrieval",
      url: "http://127.0.0.1:1",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  defp start_stub_server(handler) do
    port = free_port()

    start_supervised!(
      {Bandit, plug: {StubPlug, test_pid: self(), handler: handler}, scheme: :http, port: port}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
