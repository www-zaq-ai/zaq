defmodule Zaq.System.GrpcConfigTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.{Event, NodeRouter, System}

  @key "system.global.grpc_max_message_bytes"
  @mib 1_048_576

  test "missing setting reads as 64 MiB without inserting a default" do
    assert is_nil(System.get_config(@key))
    assert {:ok, 64 * @mib} == dispatch(:system_config_get_grpc_max_message_bytes)
    assert is_nil(System.get_config(@key))
  end

  test "Engine events persist whole MiB as bytes and reject invalid inputs without overwriting" do
    assert :ok == dispatch(:system_config_set_grpc_max_message_mib, %{mib: "16"})
    assert System.get_config(@key) == Integer.to_string(16 * @mib)
    assert {:ok, 16 * @mib} == dispatch(:system_config_get_grpc_max_message_bytes)

    for value <- [nil, "", "1.5", "64junk", 0, -1, 4096, 1.5, %{}, []] do
      assert {:error, :invalid_grpc_max_message_size} ==
               dispatch(:system_config_set_grpc_max_message_mib, %{mib: value})

      assert {:ok, 16 * @mib} == dispatch(:system_config_get_grpc_max_message_bytes)
    end
  end

  test "corrupt stored values return an explicit error rather than silently using a default" do
    for value <- ["", "oops", "0", "1048577", "4294967296"] do
      assert {:ok, _} = System.set_config(@key, value)

      assert {:error, :invalid_grpc_max_message_size} ==
               dispatch(:system_config_get_grpc_max_message_bytes)
    end
  end

  property "every allowed whole-MiB value round-trips exactly through the existing store" do
    check all(mib <- integer(1..4095), max_runs: 30) do
      assert :ok == dispatch(:system_config_set_grpc_max_message_mib, %{mib: to_string(mib)})
      assert {:ok, mib * @mib} == dispatch(:system_config_get_grpc_max_message_bytes)
    end
  end

  defp dispatch(action, request \\ %{}) do
    request
    |> Event.new(:engine, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
