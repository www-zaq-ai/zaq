defmodule Zaq.Engine.GrpcSettingsTest do
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog

  alias Zaq.Engine.{Extension, GrpcSettings}
  alias Zaq.ExtensionGateway
  alias Zaq.System, as: SystemConfig

  @mib 1_048_576

  setup do
    original = Application.fetch_env(:grpc, :max_message_length)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:grpc, :max_message_length, value)
        :error -> Application.delete_env(:grpc, :max_message_length)
      end
    end)

    :ok
  end

  test "startup loads 64 MiB by default, and saving alone does not change the running limit" do
    assert :ok = GrpcSettings.load()
    assert Application.get_env(:grpc, :max_message_length) == 64 * @mib
    assert :ok = SystemConfig.set_grpc_max_message_mib("8")
    assert Application.get_env(:grpc, :max_message_length) == 64 * @mib
    assert :ok = GrpcSettings.load()
    assert Application.get_env(:grpc, :max_message_length) == 8 * @mib
  end

  test "invalid stored configuration produces a diagnostic and a bounded startup default" do
    {:ok, _} = SystemConfig.set_config("system.global.grpc_max_message_bytes", "broken")
    assert capture_log(fn -> assert :ok = GrpcSettings.load() end) =~ "gRPC message limit"
    assert Application.get_env(:grpc, :max_message_length) == 64 * @mib
  end

  test "the encrypted stream advertises the loaded limit and rejects a larger frame prefix" do
    assert :ok = SystemConfig.set_grpc_max_message_mib("2")
    assert :ok = GrpcSettings.load()
    directory = Path.join(System.tmp_dir!(), "zg-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)

    gateway = ExtensionGateway.start!(directory)

    on_exit(fn ->
      ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    runtime = start_supervised!({Extension, name: nil, settings: settings})
    assert_receive {:gateway_hello, ^gateway, %{max_envelope_bytes: limit}}, 2_000
    assert limit == 2 * @mib
    await_health(runtime, :healthy)
    ExtensionGateway.push_wire(gateway, <<0, limit + 1::32>>)
    assert %{reason: :resource_exhausted} = await_health(runtime, :error)
  end

  defp await_health(runtime, status) do
    deadline = System.monotonic_time(:millisecond) + 2_000

    Stream.repeatedly(fn -> Extension.snapshot(server: runtime) end)
    |> Enum.find(fn health ->
      if System.monotonic_time(:millisecond) > deadline, do: flunk("health did not settle")
      if health.status != status, do: Process.sleep(5)
      health.status == status
    end)
  end
end
