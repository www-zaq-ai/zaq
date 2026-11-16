defmodule Zaq.ApplicationShutdownTest do
  # `prep_stop/1` runs while the supervision tree may already be gone. The
  # shared `RunRegistry` and `Repo` of the test VM must not be stopped, so the
  # callback is exercised in a disposable peer VM where neither was ever
  # started (the state an abnormal root-supervisor shutdown leaves behind).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1]),
        env: [{~c"ROLES", ~c"engine"}]
      })

    # The peer is linked to the test process and exits with it.
    %{peer: peer}
  end

  test "engine-role prep_stop returns the state when RunRegistry and Repo are absent", %{
    peer: peer
  } do
    assert :peer.call(peer, Process, :whereis, [Zaq.Engine.Workflows.RunRegistry]) == nil
    assert :peer.call(peer, Process, :whereis, [Zaq.Repo]) == nil
    assert :peer.call(peer, Zaq.NodeRoles, :has_any?, [[:engine]])

    state = %{marker: make_ref()}
    assert :peer.call(peer, Zaq.Application, :prep_stop, [state]) == state
  end

  describe "root supervisor exits before prep_stop (real application_master path)" do
    test "no shutdown_error is logged when the registry and Repo are already gone", %{peer: peer} do
      :ok = :peer.call(peer, Zaq.ShutdownProbeApp, :capture_logs, [])
      :ok = :peer.call(peer, Zaq.ShutdownProbeApp, :boot, [:shutdown_probe_zaq, :zaq])

      assert is_pid(:peer.call(peer, Process, :whereis, [Zaq.Engine.Workflows.RunRegistry]))

      assert :stopped =
               :peer.call(peer, Zaq.ShutdownProbeApp, :stop_root_and_wait, [:shutdown_probe_zaq])

      assert :peer.call(peer, Process, :whereis, [Zaq.Engine.Workflows.RunRegistry]) == nil

      refute Enum.any?(
               :peer.call(peer, Zaq.ShutdownProbeApp, :captured, []),
               &(&1 =~ "shutdown_error")
             )
    end

    test "control: a failing prep_stop is reported as shutdown_error by the same path", %{
      peer: peer
    } do
      :ok = :peer.call(peer, Zaq.ShutdownProbeApp, :capture_logs, [])
      :ok = :peer.call(peer, Zaq.ShutdownProbeApp, :boot, [:shutdown_probe_failing, :failing])

      assert :stopped =
               :peer.call(peer, Zaq.ShutdownProbeApp, :stop_root_and_wait, [
                 :shutdown_probe_failing
               ])

      assert Enum.any?(
               :peer.call(peer, Zaq.ShutdownProbeApp, :captured, []),
               &(&1 =~ "shutdown_error")
             )
    end
  end
end
