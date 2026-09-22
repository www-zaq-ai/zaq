defmodule Zaq.TestSupport.DiskConfigFixture do
  @moduledoc "Test fixture for an enabled Disk data-source configuration."

  alias Zaq.Channels.ChannelConfig

  def get_or_create! do
    ChannelConfig.get_by_provider("disk") || create!()
  end

  defp create! do
    attrs = %{
      name: "Disk",
      kind: "data_source",
      enabled: true,
      settings: %{"volumes" => [%{"name" => "default", "path" => "."}]}
    }

    case ChannelConfig.upsert_by_provider("disk", attrs) do
      {:ok, config} ->
        config

      {:error, changeset} ->
        raise "could not provision Disk test config: #{inspect(changeset.errors)}"
    end
  end
end
