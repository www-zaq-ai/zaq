defmodule Zaq.Channels.JidoConnectBridge.WebhookWorkerTest do
  use Zaq.DataCase, async: false

  alias Oban.Job
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoConnectBridge.WebhookWorker
  alias Zaq.Repo

  test "perform/1 returns cancel for missing config args" do
    result = WebhookWorker.perform(%Job{args: %{}})

    assert result == {:cancel, :missing_config}
  end

  test "perform/1 preserves provider mismatch cancel reason" do
    config = insert_data_source_config(:google_drive)

    result =
      WebhookWorker.perform(%Job{
        args: %{"config_id" => config.id, "provider" => "slack"}
      })

    assert result == {:cancel, :provider_mismatch}
  end

  test "perform/1 preserves config not found cancel reason" do
    result =
      WebhookWorker.perform(%Job{
        args: %{"config_id" => -1, "provider" => "google_drive"}
      })

    assert result == {:cancel, :config_not_found}
  end

  test "perform/1 preserves cancel reasons from the bridge" do
    original_bridge = Zaq.Channels.JidoConnectBridge
    original_path = Path.expand("../../../../lib/zaq/channels/jido_connect_bridge.ex", __DIR__)

    :code.purge(original_bridge)
    :code.delete(original_bridge)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string("""
    defmodule Zaq.Channels.JidoConnectBridge do
      def process_verified_webhook_job(_args), do: {:cancel, :stubbed_cancel}
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    on_exit(fn ->
      :code.purge(original_bridge)
      :code.delete(original_bridge)
      Code.compiler_options(ignore_module_conflict: true)
      Code.compile_file(original_path)
      Code.compiler_options(ignore_module_conflict: false)
    end)

    result = WebhookWorker.perform(%Job{args: %{}})

    assert result == {:cancel, :stubbed_cancel}
  end

  defp insert_data_source_config(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "data_source",
      enabled: true,
      settings: %{}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end
end
