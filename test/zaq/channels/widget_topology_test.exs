defmodule Zaq.Channels.WidgetTopologyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.WebBridge

  defmodule Adapter do
    def infrastructure_child_specs(opts) do
      send(self(), {:infrastructure_options, opts})
      {:ok, []}
    end
  end

  defmodule Config do
    def get(:zaq, :channels, _),
      do: %{web_widget: %{adapter: Adapter}, other_web: %{adapter: Adapter}}
  end

  test "widget infrastructure defaults to the local node without configuring other providers" do
    assert options(:web_widget)[:authentication] == [replica_nodes: [node()]]
    refute Keyword.has_key?(options(:other_web), :authentication)
  end

  test "authentication timings survive the membership default" do
    authentication = [token_ttl_seconds: 3600, refresh_lead_seconds: 60]
    opts = options(:web_widget, host_options: [authentication: authentication])

    assert opts[:authentication] == Keyword.put_new(authentication, :replica_nodes, [node()])
  end

  property "explicit membership is preserved rather than replaced or discovered" do
    check all(membership <- term()) do
      authentication = [replica_nodes: membership, token_ttl_seconds: 3600]

      opts =
        options(:web_widget,
          adapter_options: %{web_widget: [authentication: authentication]}
        )

      assert opts[:authentication] == authentication
    end
  end

  test "the real adapter rejects explicitly empty membership" do
    assert {:error, :provider_infrastructure_start_failed} =
             WebBridge.build_runtime_specs({:provider, :web_widget},
               adapter_options: %{web_widget: [authentication: [replica_nodes: []]]}
             )
  end

  test "the real adapter accepts explicit multi-node membership at construction" do
    membership = [node(), :"widget_peer@example.invalid"]

    assert {:ok, {nil, [_]}} =
             WebBridge.build_runtime_specs({:provider, :web_widget},
               adapter_options: %{web_widget: [authentication: [replica_nodes: membership]]}
             )
  end

  @tag timeout: 120_000
  test "named-node application startup works without deployment options" do
    run_named_vm("Application.delete_env(:zaq, :channels_supervisor_options)", 604_800)
  end

  @tag timeout: 120_000
  test "named-node application startup supplies configured provider options" do
    run_named_vm(
      """
      Application.put_env(:zaq, :channels_supervisor_options,
        adapter_options: %{web_widget: [authentication: [token_ttl_seconds: 3600]]})
      """,
      3600
    )
  end

  defp run_named_vm(configuration, token_ttl) do
    script = """
    true = Node.alive?()
    # This is evaluated after distribution starts, just as release startup is.
    #{configuration}
    {:ok, _} = Application.ensure_all_started(:zaq)
    {:ok, config} = WebWidget.Configuration.fetch()
    unless config.authentication[:replica_nodes] == [node()],
      do: raise("named-node replica membership missing")
    unless config.authentication[:token_ttl_seconds] == #{token_ttl},
      do: raise("application startup discarded provider options")
    {:ok, _} = Zaq.Channels.BridgeSupervisor.lookup_runtime("provider:web_widget")
    IO.puts("named-node widget startup verified")
    """

    name = "widget_topology_#{System.unique_integer([:positive])}"

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [
          {"MIX_ENV", "test"},
          {"ROLES", "channels"},
          {"PHX_SERVER", nil},
          {"E2E", nil},
          {"ELIXIR_ERL_OPTIONS", "-sname #{name} -setcookie #{name}_cookie"},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "named-node widget startup verified"
  end

  defp options(provider, extras \\ []) do
    assert {:ok, {nil, []}} =
             WebBridge.build_runtime_specs({:provider, provider}, [config: Config] ++ extras)

    assert_receive {:infrastructure_options, opts}
    opts
  end
end
