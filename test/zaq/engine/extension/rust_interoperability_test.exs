defmodule Zaq.Engine.Extension.RustInteroperabilityTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension
  alias Zaq.Engine.Extension.Client
  alias Zaq.ExtensionGateway
  alias Zaq.ExtensionGateway.Rust

  @moduletag :commercial_gateway

  test "real Rust Connect lists and describes Actions and executes concurrent SYNC and ASYNC over mTLS UDS" do
    binary =
      System.get_env("GATEWAY_ACTION_PROBE_BINARY") ||
        raise "Set GATEWAY_ACTION_PROBE_BINARY to the built action_probe diagnostic"

    directory = Path.join(System.tmp_dir!(), "zap-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    arguments = Path.join(directory, "arguments.json")
    File.write!(arguments, ~s({"value":2.0,"amount":3.0}))

    gateway =
      Rust.start!(directory, binary: binary, args: ["arithmetic.add", arguments], notify: self())

    on_exit(fn -> Rust.stop(gateway) end)
    start_supervised!({Extension, name: nil, settings: settings})
    output = await_probe(gateway, "")
    assert output =~ "ListActions:"
    assert output =~ "DescribeAction:"
    assert output =~ "ASYNC RELAYED consumed and receipted"
    assert output =~ "Action exchange succeeded"
  end

  defp await_probe(gateway, output) do
    receive do
      {:gateway_binary_output, ^gateway, bytes} -> await_probe(gateway, output <> bytes)
      {:gateway_binary_exit, ^gateway, 0} -> output
      {:gateway_binary_exit, ^gateway, status} -> flunk("Rust probe exited #{status}: #{output}")
    after
      15_000 -> flunk("Rust Action probe did not complete: #{output}")
    end
  end

  test "real Rust Health interoperates with the checked-in protobuf bindings over secure UDS" do
    directory = Path.join(System.tmp_dir!(), "zr-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    gateway = Rust.start!(directory)
    on_exit(fn -> Rust.stop(gateway) end)

    name = make_ref()
    assert {:ok, :healthy} = Client.health(settings: settings, connection_name: name)
    assert {:error, :not_started} = Connection.get_channel(name)
    assert {:ok, :healthy} = Client.health(settings: settings)
  end
end
