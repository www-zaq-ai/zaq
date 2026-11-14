defmodule Zaq.Engine.ExtensionTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Extension

  test "unconfigured runtime is immediately readable and does not start probes" do
    runtime = start_supervised!({Extension, name: nil, settings: []})
    assert %{status: :unconfigured, checked_at: nil} = Extension.snapshot(server: runtime)
  end

  test "invalid configuration cannot prevent runtime startup" do
    runtime = start_supervised!({Extension, name: nil, settings: [socket_path: "relative.sock"]})
    assert %{status: :error, reason: :invalid_configuration} = Extension.snapshot(server: runtime)
  end

  test "a stalled external peer cannot block snapshot reads or outlive the probe deadline" do
    directory = Path.join(System.tmp_dir!(), "ze-#{System.unique_integer([:positive])}")
    settings = Zaq.ExtensionGateway.certificates!(directory)
    path = settings[:socket_path]
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(directory)
    end)

    runtime = start_supervised!({Extension, name: nil, settings: settings, probe_timeout_ms: 500})
    assert %{status: :checking} = Extension.snapshot(server: runtime)
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    assert %{status: :checking} = Extension.snapshot(server: runtime)
    assert_snapshot(runtime, :unreachable)
    assert {:ok, _client_hello} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  defp assert_snapshot(runtime, status, attempts \\ 100)
  defp assert_snapshot(_runtime, _status, 0), do: flunk("health snapshot did not settle")

  defp assert_snapshot(runtime, status, attempts) do
    snapshot = Extension.snapshot(server: runtime)

    if snapshot.status == status do
      snapshot
    else
      Process.sleep(10)
      assert_snapshot(runtime, status, attempts - 1)
    end
  end
end
