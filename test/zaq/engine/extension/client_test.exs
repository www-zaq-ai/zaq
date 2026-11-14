defmodule Zaq.Engine.Extension.ClientTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.Client

  test "no configuration is optional; partial configuration is an error" do
    assert {:error, :unconfigured} = Client.health(settings: [])

    assert {:error, :invalid_configuration} =
             Client.health(settings: [socket_path: "/run/gateway/gateway.sock"])
  end

  property "incomplete configuration never attempts or reports a successful Health call" do
    check all(socket_path <- string(:printable), max_runs: 30) do
      assert {:error, :invalid_configuration} =
               Client.health(settings: [socket_path: socket_path])
    end
  end
end
