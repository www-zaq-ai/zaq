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
      kind: "ingestion",
      url: "https://drive.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  test "init/1 starts empty when no ingestion configs exist" do
    assert {:ok, {spec, []}} = IngestionSupervisor.init([])
    assert spec.strategy == :one_for_one
  end

  test "init/1 includes one child for mapped ingestion provider" do
    config = insert_config()

    assert {:ok, {spec, [child]}} = IngestionSupervisor.init([])

    assert spec.strategy == :one_for_one
    assert child.id == {Zaq.Channels.Ingestion.GoogleDrive, config.id}
    assert child.restart == :permanent

    {mod, fun, [arg]} = child.start
    assert mod == Zaq.Channels.Ingestion.GoogleDrive
    assert fun == :start_link
    assert arg.id == config.id
  end

  test "init/1 skips enabled ingestion providers with no adapter mapping" do
    insert_config(provider: "email", name: "Email")

    assert {:ok, {_spec, []}} = IngestionSupervisor.init([])
  end

  test "init/1 ignores disabled configs" do
    insert_config(enabled: false)

    assert {:ok, {_spec, []}} = IngestionSupervisor.init([])
  end
end
