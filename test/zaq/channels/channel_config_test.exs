defmodule Zaq.Channels.ChannelConfigTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
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

  test "changeset/2 validates required fields and inclusion" do
    changeset = ChannelConfig.changeset(%ChannelConfig{}, %{provider: "unknown", kind: "bad"})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).name
    assert "can't be blank" in errors_on(changeset).url
    assert "can't be blank" in errors_on(changeset).token
    assert "is invalid" in errors_on(changeset).provider
    assert "is invalid" in errors_on(changeset).kind
  end

  test "list_enabled_by_kind/1 returns only enabled configs for kind" do
    retrieval_enabled =
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

    _retrieval_disabled =
      insert_channel_config(%{provider: "slack", kind: "retrieval", enabled: false})

    _ingestion_enabled =
      insert_channel_config(%{provider: "google_drive", kind: "ingestion", enabled: true})

    assert [result] = ChannelConfig.list_enabled_by_kind(:retrieval)
    assert result.id == retrieval_enabled.id
  end

  test "get_by_provider/1 ignores disabled configs" do
    _disabled = insert_channel_config(%{provider: "mattermost", enabled: false})
    enabled = insert_channel_config(%{provider: "slack", enabled: true})
    enabled_id = enabled.id

    assert %ChannelConfig{id: ^enabled_id} = ChannelConfig.get_by_provider("slack")
    assert nil == ChannelConfig.get_by_provider("mattermost")
  end

  test "test_connection/2 returns unsupported provider error" do
    config = %ChannelConfig{provider: "slack"}

    assert {:error, "Testing not supported for slack"} =
             ChannelConfig.test_connection(config, "channel-1")
  end

  test "test_connection/2 dispatches to provider API module" do
    base_url =
      start_stub_server(fn conn, body ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v4/posts"

        assert %{"channel_id" => "channel-1", "message" => message} = Jason.decode!(body)
        assert String.contains?(message, "Zaq Connection Test")

        {201, %{"id" => "post-1"}}
      end)

    config = %ChannelConfig{provider: "mattermost", url: base_url, token: "token"}

    assert {:ok, %{"id" => "post-1"}} = ChannelConfig.test_connection(config, "channel-1")
  end

  defp insert_channel_config(attrs) do
    defaults = %{
      name: "Config",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://mattermost.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
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
