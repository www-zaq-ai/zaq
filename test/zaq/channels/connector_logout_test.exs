defmodule Zaq.Channels.ConnectorLogoutTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}

  defmodule Runtime do
    def lookup_runtime(id), do: Process.get({__MODULE__, id}, {:error, :not_running})
  end

  defmodule Config do
    def get(:zaq, :channels, _, _) do
      %{
        whatsapp: %{
          bridge: JidoChatBridge,
          adapter: Jido.Chat.WhatsApp.Adapter
        },
        telegram: %{bridge: JidoChatBridge, adapter: __MODULE__}
      }
    end

    def get(:zaq, :chat_bridge_supervisor_module, _, _), do: Runtime
  end

  defmodule Transport do
    def connect(config, _opts), do: {:ok, {config.observer, config.profile}}
    def stop(_, _), do: :ok

    def logout({observer, profile}, opts) do
      send(observer, {:adapter_logout, profile})
      Keyword.get(opts, :result, :ok)
    end
  end

  def sink(_, _), do: :ok

  test "configured bridge callback invokes package logout only for the selected worker" do
    first = worker("first", :ok)
    second = worker("second", :ok)
    register_runtime(1, first)
    register_runtime(2, second)

    assert :ok = CommunicationBridge.logout(%{provider: "whatsapp", id: 1}, config: Config)
    assert_receive {:adapter_logout, "first"}
    refute_receive {:adapter_logout, "second"}
    assert %{status: :logged_out} = ConnectionWorker.status(first)
    assert %{status: :connecting} = ConnectionWorker.status(second)
  end

  test "provider without a logout callback cannot affect its listener" do
    pid = worker("telegram", :ok)
    Process.put({Runtime, "telegram_1"}, {:ok, %{listener_pids: [pid]}})

    assert {:error, :unsupported} =
             CommunicationBridge.logout(%{provider: "telegram", id: 1}, config: Config)

    refute_receive {:adapter_logout, _}
  end

  test "logout failure and missing runtime are explicit errors" do
    pid = worker("failure", {:error, :transport_failed})
    register_runtime(1, pid)

    assert {:error, :logout_failed} =
             CommunicationBridge.logout(%{provider: "whatsapp", id: 1}, config: Config)

    assert_receive {:adapter_logout, "failure"}

    assert {:error, :not_running} =
             CommunicationBridge.logout(%{provider: "whatsapp", id: 2}, config: Config)
  end

  test "logout through the adapter normalizes a stopped listener exit" do
    pid = worker("stopped", :ok)
    register_runtime(1, pid)
    stop_supervised!("stopped")

    assert {:error, :logout_unavailable} =
             CommunicationBridge.logout(%{provider: "whatsapp", id: 1}, config: Config)
  end

  defp register_runtime(id, pid),
    do: Process.put({Runtime, "whatsapp_#{id}"}, {:ok, %{listener_pids: [pid]}})

  defp worker(profile, result) do
    start_supervised!(
      {ConnectionWorker,
       bridge_id: profile,
       sink_mfa: {__MODULE__, :sink, []},
       transport: Transport,
       config: %{profile: profile, observer: self()},
       connect_opts: [result: result]},
      id: profile
    )
  end
end
