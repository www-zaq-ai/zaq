defmodule Zaq.ConfidentialEventPeerTest do
  use ExUnit.Case, async: false
  alias Zaq.TestSupport.{ConfidentialAuthPeer, PeopleAuthPeer}

  @tag timeout: 300_000
  test "two real nodes verify/revoke confidential sessions while both PubSub observers see only public controls" do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    {origin, origin_node} = peer("origin")
    {engine, engine_node} = peer("engine")

    for {peer, role} <- [{origin, :origin}, {engine, :engine}] do
      assert is_pid(
               :peer.call(
                 peer,
                 ConfidentialAuthPeer,
                 :start,
                 [Zaq.Repo.config(), Application.get_env(:zaq, ZaqWeb.Endpoint), role],
                 30_000
               )
             )
    end

    assert :ok = :peer.call(origin, PeopleAuthPeer, :connect, [engine_node], 120_000)
    assert :ok = :peer.call(engine, PeopleAuthPeer, :connect, [origin_node], 120_000)

    assert %{remote_engine: true, verified_person: true, revoked: true, context_preserved: true} =
             :peer.call(origin, ConfidentialAuthPeer, :verify_remotely, [engine_node], 30_000)

    for source <- [origin, engine] do
      assert {trace, true} = :peer.call(source, ConfidentialAuthPeer, :control, [])

      for observer <- [origin, engine] do
        assert %{secret_events: 0, observed_control: true} =
                 :peer.call(observer, ConfidentialAuthPeer, :await, [trace])
      end
    end
  end

  defp peer(suffix) do
    name = String.to_atom("pr4_confidential_#{suffix}_#{System.unique_integer([:positive])}")
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, control, node} =
      :peer.start_link(%{
        name: name,
        connection: :standard_io,
        args: [~c"+S", ~c"2", ~c"-setcookie", ~c"zaq_people_auth_test" | paths]
      })

    Process.unlink(control)
    on_exit(fn -> if Process.alive?(control), do: :peer.stop(control) end)
    assert {:ok, _} = :peer.call(control, :application, :ensure_all_started, [:elixir])
    {control, node}
  end
end
