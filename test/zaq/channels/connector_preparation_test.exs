defmodule Zaq.Channels.ConnectorPreparationTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}

  defmodule DefaultBridge do
  end

  defmodule Runtime do
    def lookup_runtime(id), do: Process.get({__MODULE__, id}, {:error, :not_running})
  end

  defmodule Config do
    def get(:zaq, :channels, _, _) do
      %{
        whatsapp: %{bridge: JidoChatBridge, adapter: Jido.Chat.WhatsApp.Adapter},
        telegram: %{bridge: JidoChatBridge, adapter: __MODULE__},
        disk: %{bridge: DefaultBridge}
      }
    end

    def get(:zaq, :chat_bridge_supervisor_module, _, _), do: Runtime
  end

  defmodule UnavailableAdapterConfig do
    def get(:zaq, :channels, _, _) do
      %{whatsapp: %{bridge: JidoChatBridge, adapter: __MODULE__.Missing}}
    end
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

  test "bridges and Jido adapters without a custom disable hook proceed normally" do
    for provider <- ["disk", "telegram"] do
      assert :ok =
               CommunicationBridge.before_disable(%{id: 1, provider: provider}, %{},
                 config: Config
               )
    end

    refute_received {:adapter_logout, _}
  end

  test "prepare-disable uses the selected WhatsApp worker and existing logout permission" do
    admin = super_admin_fixture(%{must_change_password: false})
    regular = user_fixture(%{must_change_password: false})
    first = worker(1, :ok)
    second = worker(2, :ok)
    config = %{provider: "whatsapp", id: 1}

    for actor <- [nil, %{}, %{user_id: regular.id}] do
      assert {:error, :unauthorized} =
               CommunicationBridge.before_disable(config, actor, config: Config)
    end

    refute_received {:adapter_logout, _}

    assert :ok =
             CommunicationBridge.before_disable(config, %{user_id: admin.id}, config: Config)

    assert_received {:adapter_logout, "1"}
    refute_received {:adapter_logout, "2"}
    assert %{status: :logged_out} = ConnectionWorker.status(first)
    assert %{status: :connecting} = ConnectionWorker.status(second)
  end

  test "configured logout failure cannot fall back to the default disable behavior" do
    admin = super_admin_fixture(%{must_change_password: false})
    worker(1, {:error, :transport_failed})

    assert {:error, :logout_failed} =
             CommunicationBridge.before_disable(
               %{provider: "whatsapp", id: 1},
               %{user_id: admin.id},
               config: Config
             )

    assert_received {:adapter_logout, "1"}

    assert {:error, :not_running} =
             CommunicationBridge.before_disable(
               %{provider: "whatsapp", id: 2},
               %{user_id: admin.id},
               config: Config
             )
  end

  test "stopped listener exits are reported before disable can proceed" do
    admin = super_admin_fixture(%{must_change_password: false})
    worker(1, :ok)
    stop_supervised!("1")

    assert {:error, :logout_unavailable} =
             CommunicationBridge.before_disable(
               %{provider: "whatsapp", id: 1},
               %{user_id: admin.id},
               config: Config
             )
  end

  test "an unloadable configured adapter is a failure rather than an absent callback" do
    assert {:error, :nofile} =
             CommunicationBridge.before_disable(%{provider: "whatsapp", id: 1}, nil,
               config: UnavailableAdapterConfig
             )
  end

  defp worker(id, result) do
    profile = to_string(id)

    pid =
      start_supervised!(
        {ConnectionWorker,
         bridge_id: profile,
         sink_mfa: {__MODULE__, :sink, []},
         transport: Transport,
         config: %{profile: profile, observer: self()},
         connect_opts: [result: result]},
        id: profile
      )

    Process.put({Runtime, "whatsapp_#{id}"}, {:ok, %{listener_pids: [pid]}})
    pid
  end
end
