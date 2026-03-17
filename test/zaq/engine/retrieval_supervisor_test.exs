defmodule Zaq.Engine.RetrievalSupervisorTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.RetrievalSupervisor
  alias Zaq.Repo

  defp insert_mattermost_config(attrs \\ []) do
    defaults = %{
      name: "Mattermost",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://mattermost.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  describe "init/1 when no retrieval configs exist" do
    test "starts supervisor with no children" do
      assert {:ok, {spec, []}} = RetrievalSupervisor.init([])
      assert spec.strategy == :one_for_one
    end
  end

  describe "init/1 when mattermost is configured" do
    test "returns one child for the mattermost adapter" do
      config = insert_mattermost_config()

      assert {:ok, {spec, children}} = RetrievalSupervisor.init([])

      assert spec.strategy == :one_for_one
      assert length(children) == 1

      child = hd(children)
      assert child.id == {Zaq.Channels.Retrieval.Mattermost, config.id}
      assert child.restart == :permanent

      {mod, fun, [arg]} = child.start
      assert mod == Zaq.Channels.Retrieval.Mattermost
      assert fun == :connect
      assert arg.id == config.id
      assert arg.provider == "mattermost"
    end

    test "disabled config produces no children" do
      insert_mattermost_config(enabled: false)

      assert {:ok, {_spec, []}} = RetrievalSupervisor.init([])
    end

    test "unknown provider is skipped" do
      # "teams" is valid in the ChannelConfig schema but has no adapter
      # mapped in RetrievalSupervisor's @adapters, so it should be skipped.
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Teams",
        provider: "teams",
        kind: "retrieval",
        url: "https://teams.example.com",
        token: "test-token",
        enabled: true
      })
      |> Repo.insert!()

      assert {:ok, {_spec, []}} = RetrievalSupervisor.init([])
    end
  end
end
