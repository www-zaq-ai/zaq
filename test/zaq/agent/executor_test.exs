defmodule Zaq.Agent.ExecutorTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
  end

  defmodule StubServerManager do
    def ensure_server(configured_agent) do
      send(self(), {:ensure_server, configured_agent})
      {:ok, :stub_server}
    end

    def ensure_server_by_id(configured_agent, server_id) do
      send(self(), {:ensure_server_by_id, configured_agent, server_id})
      {:ok, :stub_server_scoped}
    end
  end

  defmodule StubFactory do
    def ask_with_config(_server, _content, _configured_agent), do: {:ok, :request}
    def await(:request, timeout: 45_000), do: {:ok, %{result: "stubbed answer"}}
  end

  defmodule StubNodeRouter do
    def call(:channels, Zaq.Channels.Router, :send_typing, _args), do: :ok
    def call(_role, module, function, args), do: apply(module, function, args)
  end

  @incoming %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

  @base_opts [
    agent_id: "stub",
    agent_module: StubAgent,
    server_manager_module: StubServerManager,
    factory_module: StubFactory,
    node_router: StubNodeRouter
  ]

  describe "run/2 :scope opt" do
    test "with :scope opt uses agent name as server id — {agent_name}:{scope}" do
      opts = Keyword.put(@base_opts, :scope, "99")

      Executor.run(@incoming, opts)

      assert_received {:ensure_server_by_id, _configured_agent, "Stub Agent:99"}
      refute_received {:ensure_server, _}
    end

    test "without :scope opt falls back to shared ensure_server" do
      Executor.run(@incoming, @base_opts)

      assert_received {:ensure_server, _configured_agent}
      refute_received {:ensure_server_by_id, _, _}
    end
  end
end
