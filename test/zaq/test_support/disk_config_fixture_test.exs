defmodule Zaq.TestSupport.DiskConfigFixtureTest do
  use Zaq.DataCase, async: true

  import Ecto.Query

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.TestSupport.DiskConfigFixture

  test "provisions and reuses an enabled Disk configuration" do
    Repo.delete_all(from(config in ChannelConfig, where: config.provider == "disk"))

    config = DiskConfigFixture.get_or_create!()

    assert config.provider == "disk"
    assert config.enabled
    assert config.settings == %{"volumes" => [%{"name" => "default", "path" => "."}]}
    assert DiskConfigFixture.get_or_create!().id == config.id
  end
end
