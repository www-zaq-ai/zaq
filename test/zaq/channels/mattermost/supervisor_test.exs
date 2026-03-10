defmodule Zaq.Channels.Mattermost.SupervisorTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Mattermost.Supervisor, as: MattermostSupervisor
  alias Zaq.Repo

  defp insert_mattermost_config(attrs \\ []) do
    defaults = %{
      name: "Mattermost",
      provider: "mattermost",
      url: "https://mattermost.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  describe "init/1 when mattermost is not configured" do
    test "starts supervisor with no children" do
      assert {:ok, {spec, []}} = MattermostSupervisor.init([])
      assert spec.strategy == :one_for_one
    end
  end

  describe "init/1 when mattermost is configured" do
    test "returns two children: PendingQuestions and Client" do
      insert_mattermost_config()

      assert {:ok, {spec, children}} = MattermostSupervisor.init([])

      assert spec.strategy == :one_for_one
      assert length(children) == 2

      child_ids = Enum.map(children, & &1.id)
      assert Zaq.Channels.PendingQuestions in child_ids
      assert Zaq.Channels.Mattermost.Client in child_ids
    end

    test "builds wss:// URI from https:// URL" do
      insert_mattermost_config(url: "https://mattermost.example.com")

      assert {:ok, {_spec, children}} = MattermostSupervisor.init([])

      client = Enum.find(children, &(&1.id == Zaq.Channels.Mattermost.Client))
      {_mod, _fun, [opts]} = client.start
      assert Keyword.get(opts, :uri) == "wss://mattermost.example.com/api/v4/websocket"
    end

    test "builds ws:// URI from http:// URL" do
      insert_mattermost_config(url: "http://mattermost.local")

      assert {:ok, {_spec, children}} = MattermostSupervisor.init([])

      client = Enum.find(children, &(&1.id == Zaq.Channels.Mattermost.Client))
      {_mod, _fun, [opts]} = client.start
      assert Keyword.get(opts, :uri) == "ws://mattermost.local/api/v4/websocket"
    end

    test "disabled config is treated as not configured" do
      insert_mattermost_config(enabled: false)

      assert {:ok, {_spec, []}} = MattermostSupervisor.init([])
    end
  end
end
