defmodule Zaq.People.AuthRateLimiterPeerTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.WhatsApp.Storage.Runtime, as: SessionStorage
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.People.AuthRateLimiter
  alias Zaq.TestSupport.PeopleAuthPeer

  @tag timeout: 360_000
  test "actual Application startup gates the complete Channels subtree by role" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])

    for roles <- [[:channels], [:engine], [:channels, :engine]] do
      {control, peer_node} = peer("roles")

      assert :ok =
               :peer.call(
                 control,
                 PeopleAuthPeer,
                 :start_application,
                 [Application.get_all_env(:zaq), roles],
                 120_000
               )

      root = :peer.call(control, Supervisor, :which_children, [Zaq.Supervisor])
      applications = :peer.call(control, Application, :started_applications, [])
      assert List.keymember?(applications, :jido_chat_whatsapp, 0)
      refute List.keymember?(root, Ingress, 0)
      refute List.keymember?(root, Zaq.People.AuthRateLimiter, 0)

      if :channels in roles do
        assert {Zaq.Channels.Supervisor, _, :supervisor, _} =
                 List.keyfind(root, Zaq.Channels.Supervisor, 0)

        children = :peer.call(control, Supervisor, :which_children, [Zaq.Channels.Supervisor])

        assert Enum.sort(Enum.map(children, &elem(&1, 0))) ==
                 Enum.sort([
                   Ingress,
                   Zaq.Channels.BridgeSupervisor
                 ])

        # This fixture starts with no providers configured. Storage belongs to
        # provider bootstrap, not to the static Channels role supervisor.
        assert nil == :peer.call(control, Process, :whereis, [SessionStorage])

        refute :jido_chat_whatsapp_sessions in :peer.call(control, :mnesia, :system_info, [
                 :tables
               ])

        whatsapp = %{
          whatsapp: %{
            bridge: JidoChatBridge,
            adapter: Jido.Chat.WhatsApp.Adapter,
            ingress_mode: :linked_device
          }
        }

        assert :ok = :peer.call(control, Application, :put_env, [:zaq, :channels, whatsapp])

        assert :ok =
                 :peer.call(control, JidoChatBridge, :sync_provider_runtime, [
                   {:provider, :whatsapp},
                   []
                 ])

        children =
          :peer.call(control, DynamicSupervisor, :which_children, [Zaq.Channels.BridgeSupervisor])

        assert {_, store, :supervisor, [SessionStorage]} =
                 Enum.find(children, fn {_, _, _, modules} -> modules == [SessionStorage] end)

        assert {:ok, %{state_pid: nil, listener_pids: [^store]}} =
                 :peer.call(control, Zaq.Channels.Supervisor, :lookup_runtime, [
                   "provider:whatsapp"
                 ])

        assert :ram_copies ==
                 :peer.call(control, :mnesia, :table_info, [
                   :jido_chat_whatsapp_sessions,
                   :storage_type
                 ])

        refute :peer.call(control, :mnesia, :system_info, [:use_dir])

        assert peer_node ==
                 :peer.call(control, Zaq.NodeRouter, :find_node, [Zaq.Channels.Supervisor])
      else
        assert nil == :peer.call(control, Process, :whereis, [Zaq.Channels.Supervisor])
        assert nil == :peer.call(control, Process, :whereis, [Zaq.Channels.BridgeSupervisor])
        assert nil == :peer.call(control, Process, :whereis, [Ingress])

        refute :jido_chat_whatsapp_sessions in :peer.call(control, :mnesia, :system_info, [
                 :tables
               ])
      end

      if :engine in roles do
        assert {Zaq.Engine.Supervisor, _, :supervisor, _} =
                 List.keyfind(root, Zaq.Engine.Supervisor, 0)

        children = :peer.call(control, Supervisor, :which_children, [Zaq.Engine.Supervisor])
        assert {AuthRateLimiter, _, :supervisor, _} = List.keyfind(children, AuthRateLimiter, 0)
      else
        assert nil == :peer.call(control, Process, :whereis, [Zaq.Engine.Supervisor])
        assert nil == :peer.call(control, Process, :whereis, [AuthRateLimiter])
      end

      :peer.stop(control)
    end
  end

  test "official increment broadcasts converge between real ETS backends on two BEAM nodes" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    {a, a_node} = peer("a")
    {b, b_node} = peer("b")

    for control <- [a, b],
        do: assert(:ok = :peer.call(control, PeopleAuthPeer, :start, [Zaq.Repo.config()], 15_000))

    assert :ok = :peer.call(a, PeopleAuthPeer, :connect, [b_node], 120_000)
    assert :ok = :peer.call(b, PeopleAuthPeer, :connect, [a_node], 120_000)
    ip = {192, 0, 2, 42}
    assert :ok = :peer.call(b, Ingress, :check_identification, [ip])
    observer = :peer.call(b, PeopleAuthPeer, :observer, [])
    assert List.duplicate(:ok, 10) == :peer.call(a, PeopleAuthPeer, :record, [ip, 10])
    assert :ok = :peer.call(b, PeopleAuthPeer, :await, [observer])

    assert {:error, {:rate_limited, retry}} =
             :peer.call(b, Ingress, :check_identification, [ip])

    assert retry > 0 and retry <= 600_000

    assert {:error, {:rate_limited, _}} =
             :peer.call(a, Ingress, :check_identification, [ip])

    # The saturated Channels budget must not consume Engine issuance quota.
    observer = :peer.call(b, PeopleAuthPeer, :observer, [])

    assert List.duplicate(:ok, 5) ==
             :peer.call(a, PeopleAuthPeer, :record_engine_person, [42, 5])

    assert :ok = :peer.call(b, PeopleAuthPeer, :await, [observer])

    assert {:error, {:rate_limited, _}} =
             :peer.call(b, AuthRateLimiter, :hit, [:engine, {:send_person, 42}, 900_000, 5])

    assert :ok =
             :peer.call(b, AuthRateLimiter, :hit, [:engine, {:send_person, 43}, 900_000, 5])
  end

  test "Engine-only and Channels-only runtimes use separate role-local infrastructure" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    {engine, engine_node} = peer("engine")
    {channels, channels_node} = peer("channels")

    assert :ok =
             :peer.call(engine, PeopleAuthPeer, :start, [Zaq.Repo.config(), [:engine]], 15_000)

    assert :ok =
             :peer.call(
               channels,
               PeopleAuthPeer,
               :start,
               [Zaq.Repo.config(), [:channels]],
               15_000
             )

    assert nil == :peer.call(engine, Process, :whereis, [Ingress])
    assert nil == :peer.call(channels, Process, :whereis, [AuthRateLimiter])

    assert {:error, :rate_limiter_unavailable} =
             :peer.call(channels, Ingress, :check_identification, [{192, 0, 2, 1}])

    assert :ok = :peer.call(engine, PeopleAuthPeer, :connect, [channels_node], 120_000)
    assert :ok = :peer.call(channels, PeopleAuthPeer, :connect, [engine_node], 120_000)
    assert :ok = :peer.call(channels, PeopleAuthPeer, :refresh, [])
    # Channels bootstraps remotely and serves requests without any local Repo.
    assert nil == :peer.call(channels, Process, :whereis, [Zaq.Repo])
    assert :ok = :peer.call(channels, Ingress, :check_identification, [{192, 0, 2, 1}])
    assert :ok = :peer.call(channels, Ingress, :record_failed_identification, [{192, 0, 2, 1}])

    assert :ok =
             :peer.call(
               engine,
               AuthRateLimiter,
               :hit,
               [:engine, {:send_person, 42}, 900_000, 5]
             )
  end

  defp peer(suffix) do
    name = String.to_atom("pr3_rate_#{suffix}_#{System.unique_integer([:positive])}")
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
