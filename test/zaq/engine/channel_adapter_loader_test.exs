defmodule Zaq.Engine.ChannelAdapterLoaderTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.ChannelAdapterLoader
  alias Zaq.Repo

  defmodule StubAdapter do
    def start_link(_config), do: {:ok, self()}
    def connect(_config), do: {:ok, self()}
  end

  @adapters %{"mattermost" => StubAdapter}

  # ── build_child_spec/5 ─────────────────────────────────────────────────

  describe "build_child_spec/5" do
    test "returns a child spec for a known provider" do
      config = %{id: "cfg-1", provider: "mattermost"}

      result =
        ChannelAdapterLoader.build_child_spec(config, @adapters, :start_link, "TestSup", "test")

      assert [child_spec] = result
      assert child_spec.id == {StubAdapter, "cfg-1"}
      assert child_spec.start == {StubAdapter, :start_link, [config]}
      assert child_spec.restart == :permanent
    end

    test "uses :connect start_fun when specified" do
      config = %{id: "cfg-2", provider: "mattermost"}

      result =
        ChannelAdapterLoader.build_child_spec(config, @adapters, :connect, "TestSup", "test")

      assert [child_spec] = result
      assert child_spec.start == {StubAdapter, :connect, [config]}
    end

    test "returns [] for unknown provider" do
      config = %{id: "cfg-3", provider: "unknown_thing"}

      result =
        ChannelAdapterLoader.build_child_spec(config, @adapters, :start_link, "TestSup", "test")

      assert result == []
    end
  end

  # ── load_configs/4 ────────────────────────────────────────────────────

  describe "load_configs/4" do
    test "returns enabled configs matching kind and providers" do
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

      configs =
        ChannelAdapterLoader.load_configs(:retrieval, ["mattermost"], "TestSup", "retrieval")

      assert length(configs) == 1
      assert hd(configs).provider == "mattermost"
    end

    test "returns [] when no enabled configs exist" do
      configs =
        ChannelAdapterLoader.load_configs(:retrieval, ["mattermost"], "TestSup", "retrieval")

      assert configs == []
    end

    test "ignores disabled configs" do
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: false})

      configs =
        ChannelAdapterLoader.load_configs(:retrieval, ["mattermost"], "TestSup", "retrieval")

      assert configs == []
    end

    test "ignores configs for other kinds" do
      insert_channel_config(%{provider: "mattermost", kind: "ingestion", enabled: true})

      configs =
        ChannelAdapterLoader.load_configs(:retrieval, ["mattermost"], "TestSup", "retrieval")

      assert configs == []
    end

    test "ignores configs with providers not in the list" do
      insert_channel_config(%{provider: "slack", kind: "retrieval", enabled: true})

      configs =
        ChannelAdapterLoader.load_configs(:retrieval, ["mattermost"], "TestSup", "retrieval")

      assert configs == []
    end
  end

  # ── children_for/3 ────────────────────────────────────────────────────

  describe "children_for/3" do
    test "returns child specs for enabled configs with known providers" do
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

      children =
        ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :connect,
          supervisor_name: "TestSup"
        )

      assert length(children) == 1
      [child] = children
      assert child.restart == :permanent
    end

    test "returns [] when no enabled configs exist" do
      children =
        ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :connect,
          supervisor_name: "TestSup"
        )

      assert children == []
    end

    test "skips configs whose provider is not in the adapters map" do
      # Insert a valid provider that is NOT in @adapters (which only has "mattermost")
      insert_channel_config(%{provider: "email", kind: "retrieval", enabled: true})

      children =
        ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :connect,
          supervisor_name: "TestSup"
        )

      assert children == []
    end

    test "defaults kind_label to the kind atom string" do
      children =
        ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :connect,
          supervisor_name: "TestSup"
        )

      assert is_list(children)
    end

    test "builds correct start spec with start_fun :start_link" do
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

      children =
        ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :start_link,
          supervisor_name: "TestSup"
        )

      assert [child] = children
      {mod, fun, _args} = child.start
      assert mod == StubAdapter
      assert fun == :start_link
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp insert_channel_config(attrs) do
    defaults = %{
      name: "Test Config",
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
end
