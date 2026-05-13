defmodule Zaq.Engine.IngestionSupervisorTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.IngestionSupervisor
  alias Zaq.Repo

  defp insert_config(attrs \\ []) do
    defaults = %{
      name: "Google Drive",
      provider: "google_drive",
      kind: "data_source",
      url: "https://drive.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  test "init/1 starts empty when no ingestion adapters are mapped" do
    assert {:ok, {spec, []}} = IngestionSupervisor.init([])
    assert spec.strategy == :one_for_one
  end

  test "init/1 does not start channel-managed data source providers" do
    config = insert_config()

    assert {:ok, {spec, []}} = IngestionSupervisor.init([])

    assert spec.strategy == :one_for_one
    assert config.provider == "google_drive"
  end

  test "init/1 skips enabled retrieval providers in ingestion supervisor" do
    insert_config(provider: "slack", name: "Slack")

    assert {:ok, {_spec, []}} = IngestionSupervisor.init([])
  end

  test "init/1 ignores disabled configs" do
    insert_config(enabled: false)

    assert {:ok, {_spec, []}} = IngestionSupervisor.init([])
  end
end
