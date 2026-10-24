defmodule Zaq.Channels.ListenerRestartPolicyTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.JidoChatBridge

  defmodule Listener do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner) do
      send(owner, {:listener_started, self()})
      {:ok, owner}
    end

    @impl true
    def handle_cast(:invalid_credentials, owner),
      do: {:stop, {:auth_failed, :invalid_token}, owner}
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{adapter: Jido.Chat.Mattermost.Adapter, ingress_mode: :websocket},
      whatsapp: %{adapter: Jido.Chat.WhatsApp.Adapter, ingress_mode: :linked_device}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    :ok
  end

  @tag capture_log: true
  test "terminal listener failures preserve siblings and allow explicit recovery" do
    {_state, [spec]} =
      JidoChatBridge.runtime_specs(config("mattermost"), "failed", channel_ids: :all)

    assert spec.restart == :temporary
    assert {Jido.Chat.Mattermost.Listener, :start_link, _} = spec.start

    # Exercise the selected production restart policy with deterministic failures,
    # without opening a network connection or supplying real credentials.
    spec = %{spec | start: {Listener, :start_link, [self()]}}
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, healthy} = DynamicSupervisor.start_child(supervisor, {Agent, fn -> :healthy end})

    for _attempt <- 1..5 do
      assert {:ok, failed} = DynamicSupervisor.start_child(supervisor, spec)
      assert_receive {:listener_started, ^failed}
      monitor = Process.monitor(failed)
      GenServer.cast(failed, :invalid_credentials)
      assert_receive {:DOWN, ^monitor, :process, ^failed, {:auth_failed, :invalid_token}}
      refute_receive {:listener_started, _}
      assert Process.alive?(supervisor)
      assert Agent.get(healthy, & &1) == :healthy
    end

    assert {:ok, recovered} = DynamicSupervisor.start_child(supervisor, spec)
    assert_receive {:listener_started, ^recovered}
    assert Process.alive?(recovered)
    assert Agent.get(healthy, & &1) == :healthy
  end

  test "linked-device listeners retain the adapter restart policy" do
    config =
      Map.put(config("whatsapp"), :authentication_connection_options, %{profile: "restart-test"})

    {_state, [spec]} = JidoChatBridge.runtime_specs(config, "linked", channel_ids: :all)

    assert {Jido.Chat.WhatsApp.ConnectionWorker, :start_link, _} = spec.start
    assert Map.get(spec, :restart, :permanent) == :permanent
  end

  defp config(provider) do
    %{id: 42, provider: provider, url: "https://example.invalid", token: "fixture", settings: %{}}
  end
end
