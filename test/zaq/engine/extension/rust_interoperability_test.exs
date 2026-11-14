defmodule Zaq.Engine.Extension.RustInteroperabilityTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension.Client
  alias Zaq.ExtensionGateway
  alias Zaq.ExtensionGateway.Rust

  @moduletag :commercial_gateway

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
