defmodule Zaq.Channels.Web.AdapterContractTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, Bridge, Supervisor, WebBridge}
  alias Zaq.Channels.Web.{Command, Context}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event

  defmodule Builder do
    @behaviour Zaq.Channels.WebBridge

    @impl true
    def build_runtime_specs(config, hooks) do
      send(config.settings["test_pid"], {:hooks, hooks})
      send(config.settings["test_pid"], {:runtime_settings, config.settings})

      if config.settings["fail"],
        do: {:error, :fixture_failure},
        else:
          {:ok, {%{id: :widget_state, start: {Agent, :start_link, [fn -> config.id end]}}, []}}
    end

    @impl true
    def installation(%{id: id}, base_url, scope: "/channels"),
      do: {:ok, "<script src=\"#{base_url}/widget.js\" data-widget-id=\"#{id}\"></script>"}
  end

  defmodule InvalidSnippetBuilder do
    def installation(_, _, _), do: {:ok, %{secret: "not a snippet"}}
  end

  defmodule RaisingSnippetBuilder do
    def installation(_, _, _), do: raise("secret failure details")
  end

  defmodule OtherAdapter do
    @behaviour Zaq.Channels.WebBridge
    def build_runtime_specs(config, hooks) do
      send(config.settings["test_pid"], {:other_adapter, config.id, hooks})
      {:ok, {%{id: :other, start: {Agent, :start_link, [fn -> :other end]}}, []}}
    end

    def infrastructure_child_specs(opts) do
      initializer = fn ->
        if owner = opts[:owner], do: send(owner, {:provider_started, self()})
        opts
      end

      {:ok, [%{id: :other, start: {Agent, :start_link, [initializer]}}]}
    end

    def installation(%{id: id}, base_url, scope: "/channels"),
      do: {:ok, "#{base_url}/other/#{id}"}

    def ingress_status(_, _), do: {:ok, %{status: :pending, summary: "Other transport"}}
  end

  defmodule RelayBridge do
    def installation(%{config: config}, opts),
      do: {:ok, %{bridge_received: config.id, confidential: opts[:confidential]}}
  end

  defmodule RelayConfig do
    def get(:zaq, :channels, _),
      do: %{relay_web: %{bridge: RelayBridge, adapter: :missing_adapter}}
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.merge(previous, %{
        web_widget: %{bridge: WebBridge, adapter: Builder},
        other_web: %{bridge: WebBridge, adapter: OtherAdapter}
      })
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    config = %{
      id: System.unique_integer([:positive]),
      provider: "web_widget",
      enabled: true,
      settings: %{
        "test_pid" => self(),
        "display_name" => "Support",
        "allowed_domains" => ["https://parent.example.test"]
      }
    }

    on_exit(fn -> WebBridge.stop_runtime(config) end)
    %{config: config}
  end

  test "runtime construction binds connector ID and supplies only shared contracts", %{
    config: config
  } do
    assert :ok = WebBridge.start_runtime(config)
    assert_receive {:hooks, hooks}

    assert Enum.sort(Map.keys(hooks)) == [
             :command,
             :context,
             :delivery,
             :message,
             :response,
             :sink_mfa
           ]

    assert hooks.message == Zaq.Channels.Web.Message
    assert hooks.command == Zaq.Channels.Web.Command
    assert hooks.context == Zaq.Channels.Web.Context
    assert hooks.sink_mfa == {WebBridge, :from_adapter, [%{id: config.id}]}
    refute Map.has_key?(hooks, :allowed_domains)
    refute Map.has_key?(hooks, :stylesheet_url)
    assert {:ok, %{state_pid: pid}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.start_runtime(config)
    assert {:ok, %{state_pid: ^pid}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.stop_runtime(config)
    refute Process.alive?(pid)
  end

  test "adapter capabilities remain available independently of connector runtime", %{
    config: config
  } do
    assert {:ok, %{resolved: %{runtime: true, installation: true}}} =
             WebBridge.capability_snapshot(config)

    assert {:error, :not_running} = Supervisor.lookup_runtime("web_widget_#{config.id}")

    assert :ok = WebBridge.start_runtime(config)
    assert {:ok, _} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.stop_runtime(config)

    assert {:error, :not_running} = Supervisor.lookup_runtime("web_widget_#{config.id}")

    assert {:ok, %{resolved: %{runtime: true, installation: true}}} =
             WebBridge.capability_snapshot(config)
  end

  test "provider capabilities use the shared delivery contract without a saved connector" do
    assert {:ok, snapshot} = Bridge.capability_snapshot("web_widget", %{scope: :provider})

    assert snapshot.kind == :communication
    assert snapshot.required == Bridge.required_capabilities(:communication)
    assert snapshot.labels == Bridge.capability_meta(:communication)

    assert Enum.sort(snapshot.unsupported) == [
             :audio,
             :file,
             :image,
             :reactions,
             :threads,
             :video
           ]

    assert snapshot.resolved == %{
             text: :native,
             streaming: :native,
             typing: :native,
             edit_messages: :native,
             mode: "websocket",
             runtime: true,
             installation: true
           }
  end

  test "delivery capabilities remain visible when no widget adapter is configured" do
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge})
    )

    assert {:ok, snapshot} = Bridge.capability_snapshot("web_widget", %{scope: :provider})
    assert snapshot.resolved.text == :native
    assert snapshot.resolved.streaming == :native
    assert snapshot.resolved.typing == :native
    assert snapshot.resolved.edit_messages == :native
    assert snapshot.resolved.mode == "websocket"
    refute snapshot.resolved.runtime
    refute snapshot.resolved.installation
  end

  test "authentication and cookie settings reach the adapter only in server configuration", %{
    config: config
  } do
    settings =
      Map.merge(config.settings, %{
        "identity_issuer" => "parent_issuer",
        "identity_audience" => "widget_audience",
        "same_site" => "Strict"
      })

    assert :ok = WebBridge.start_runtime(%{config | settings: settings})
    assert_receive {:runtime_settings, ^settings}
    assert_receive {:hooks, hooks}
    refute Map.has_key?(hooks, :identity_issuer)
    refute Map.has_key?(hooks, :identity_audience)
    refute Map.has_key?(hooks, :same_site)
  end

  test "changed configuration restarts, unchanged preserves, disable stops", %{config: config} do
    assert :ok = WebBridge.sync_runtime(nil, config)
    assert {:ok, %{state_pid: initial}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.sync_runtime(config, config)
    assert {:ok, %{state_pid: ^initial}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    changed = put_in(config.settings["display_name"], "New display")
    assert :ok = WebBridge.sync_runtime(config, changed)
    assert {:ok, %{state_pid: replacement}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    refute replacement == initial
    refute Process.alive?(initial)
    assert :ok = WebBridge.sync_runtime(changed, %{changed | enabled: false})
    refute Process.alive?(replacement)
  end

  test "construction failure is surfaced and BO requires no widget runtime", %{config: config} do
    assert {:error, :fixture_failure} =
             WebBridge.start_runtime(put_in(config.settings["fail"], true))

    assert {:error, :not_running} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.start_runtime(%{provider: "web", id: 0})
  end

  test "configuration rejects client-selected IDs and invalid style/domain inputs" do
    base = %{name: "Widget", provider: "web_widget", kind: "retrieval"}

    for settings <- [
          %{"widget_id" => 999},
          %{"allowed_domains" => ["*"]},
          %{"stylesheet_url" => "https://remote.test/widget.css"},
          %{"display_name" => 15}
        ] do
      refute ChannelConfig.changeset(%ChannelConfig{}, Map.put(base, :settings, settings)).valid?
    end

    assert ChannelConfig.changeset(
             %ChannelConfig{},
             Map.put(base, :settings, %{
               "allowed_domains" => ["https://parent.example.test"],
               "display_name" => "Support"
             })
           ).valid?
  end

  test "trusted adapter generates an installation snippet with only ID and base URL", %{
    config: config
  } do
    assert {:ok, snippet} =
             installation(config, "https://zaq.example.test")

    assert snippet ==
             "<script src=\"https://zaq.example.test/widget.js\" data-widget-id=\"#{config.id}\"></script>"

    assert {:error, :invalid_request} =
             installation(%{config | id: 0}, "https://zaq.example.test")

    assert {:error, :invalid_request} = installation(config, nil)
  end

  test "missing, malformed and raising snippet callbacks return bounded errors", %{config: config} do
    channels = Application.get_env(:zaq, :channels)

    for {builder, error} <- [
          {nil, :unsupported},
          {InvalidSnippetBuilder, :invalid_installation},
          {RaisingSnippetBuilder, :installation_failed}
        ] do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: builder})
      )

      assert {:error, ^error} =
               installation(config, "https://zaq.example.test")
    end
  end

  test "multiple runtime configurations remain isolated during teardown", %{config: config} do
    other = %{config | id: config.id + 1}
    on_exit(fn -> WebBridge.stop_runtime(other) end)
    assert :ok = WebBridge.start_runtime(config)
    assert :ok = WebBridge.start_runtime(other)
    assert {:ok, %{state_pid: first}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert {:ok, %{state_pid: second}} = Supervisor.lookup_runtime("web_widget_#{other.id}")
    assert :ok = WebBridge.stop_runtime(config)
    refute Process.alive?(first)
    assert Process.alive?(second)
  end

  test "missing adapter fails explicitly, while disabled runtime needs no adapter", %{
    config: config
  } do
    channels = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, Map.put(channels, :web_widget, %{bridge: WebBridge}))
    assert {:error, :unsupported} = WebBridge.start_runtime(config)
    assert :ok = WebBridge.sync_runtime(nil, %{config | enabled: false})
  end

  test "sink refuses a context bound to another widget and event-provided replacements", %{
    config: config
  } do
    {:ok, context} =
      Context.new(nil,
        consumer: :widget,
        sender_id: "trusted",
        channel_config_id: config.id + 1
      )

    {:ok, command} = Command.new(%{request_id: "r1", type: :conversation_init})

    assert {:error, :unauthorized} =
             WebBridge.from_adapter(config, command, context: context)

    assert {:error, :unauthorized} = WebBridge.from_adapter(config, %{context: context}, [])
  end

  test "ingress revalidates stylesheet URLs in manually constructed commands", %{config: config} do
    {:ok, context} =
      Context.new(nil, consumer: :widget, sender_id: "trusted", channel_config_id: config.id)

    command = %Command{
      request_id: "r1",
      type: :conversation_init,
      params: %{stylesheet_url: "/private.css"}
    }

    assert {:error, {:invalid_field, :stylesheet_url}} =
             WebBridge.handle_from_listener(config, command, context: context)
  end

  test "another provider delegates runtime, installation and status without bridge edits", %{
    config: config
  } do
    other = %{config | provider: "other_web"}
    on_exit(fn -> WebBridge.stop_runtime(other) end)
    assert :ok = WebBridge.start_runtime(other)
    assert_receive {:other_adapter, id, hooks}
    assert id == config.id
    assert hooks.sink_mfa == {WebBridge, :from_adapter, [%{id: id}]}
    assert {:ok, "https://host/other/" <> _} = installation(other, "https://host")

    assert {:ok, %{status: :pending, summary: "Other transport"}} =
             WebBridge.channel_ingress_status(other)

    assert {:error, :not_running} = Supervisor.lookup_runtime("web_widget_#{id}")
  end

  test "startup options are passed opaquely and optional infrastructure has no flag" do
    opts = [host_options: [arbitrary_transport: %{opaque: make_ref()}]]
    assert :ok = WebBridge.start_runtime({:provider, :other_web}, opts)
    on_exit(fn -> Supervisor.stop_bridge_runtime(%{}, "provider:other_web") end)
    assert {:ok, %{listener_pids: [pid]}} = Supervisor.lookup_runtime("provider:other_web")

    assert Agent.get(pid, & &1) ==
             opts[:host_options]
             |> Keyword.put_new(:pubsub_server, Zaq.PubSub)
             |> Keyword.put_new(:scope, "/channels")

    assert :ok = WebBridge.start_runtime({:provider, :web_widget}, opts)
    assert {:ok, OtherAdapter} = WebBridge.adapter_for("other_web")
  end

  test "WebBridge selects provider overrides without changing shared options" do
    shared = [pubsub_server: Zaq.PubSub, opaque: %{value: make_ref()}]

    opts = [
      host_options: shared,
      adapter_options: %{other_web: [opaque: :override], web_widget: [opaque: :wrong_provider]}
    ]

    assert :ok = WebBridge.start_runtime({:provider, :other_web}, opts)
    on_exit(fn -> Supervisor.stop_bridge_runtime(%{}, "provider:other_web") end)
    assert {:ok, %{listener_pids: [pid]}} = Supervisor.lookup_runtime("provider:other_web")

    assert Agent.get(pid, & &1) == [
             scope: "/channels",
             pubsub_server: Zaq.PubSub,
             opaque: :override
           ]

    assert opts[:host_options] == shared
  end

  test "trusted provider options survive supervised restart and subsequent connector enable", %{
    config: config
  } do
    # Other crash-test modules use this shared supervisor too. Start with a fresh
    # restart budget, leaving this provider absent until its trusted options arrive.
    channels = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, Map.delete(channels, :other_web))

    try do
      :ok = Elixir.Supervisor.terminate_child(Supervisor, Zaq.Channels.BridgeSupervisor)
      assert {:ok, _} = Elixir.Supervisor.restart_child(Supervisor, Zaq.Channels.BridgeSupervisor)
    after
      Application.put_env(:zaq, :channels, channels)
    end

    trusted = [owner: self(), scope: "/channels", opaque: make_ref()]
    assert :ok = WebBridge.start_runtime({:provider, :other_web}, host_options: trusted)
    on_exit(fn -> Supervisor.stop_bridge_runtime(%{}, "provider:other_web") end)
    assert_receive {:provider_started, initial}
    original_opts = Agent.get(initial, & &1)

    Process.exit(initial, :kill)
    assert_receive {:provider_started, replacement}, 1_000
    DynamicSupervisor.which_children(Zaq.Channels.BridgeSupervisor)

    assert {:ok, %{listener_pids: [^replacement]}} =
             Supervisor.lookup_runtime("provider:other_web")

    assert Agent.get(replacement, & &1) == original_opts

    connector = %{config | provider: "other_web"}
    assert :ok = WebBridge.start_runtime(connector)
    assert :ok = WebBridge.stop_runtime(connector)
    assert Process.alive?(replacement)
    assert Agent.get(replacement, & &1) == original_opts
  end

  test "concurrent provider starts share children independently of connectors", %{config: config} do
    opts = [host_options: [opaque: make_ref()]]
    on_exit(fn -> Supervisor.stop_bridge_runtime(%{}, "provider:other_web") end)

    results =
      1..8
      |> Task.async_stream(fn _ -> WebBridge.start_runtime({:provider, :other_web}, opts) end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, %{listener_pids: [shared]}} = Supervisor.lookup_runtime("provider:other_web")
    other = %{config | provider: "other_web"}
    assert :ok = WebBridge.start_runtime(other)
    assert :ok = WebBridge.stop_runtime(other)
    assert Process.alive?(shared)
  end

  test "installation event requires confidentiality and matching provider scope", %{
    config: config
  } do
    request = %{
      provider: config.provider,
      config: config,
      op: :installation,
      base_url: "https://host"
    }

    event = Event.new(request, :channels)

    assert {:error, :confidential_event_required} =
             Api.handle_event(event, :channel_installation, %{}).response

    event = Event.new(%{request | provider: "other_web"}, :channels, opts: [confidential: true])

    assert {:error, :invalid_request} =
             Api.handle_event(event, :channel_installation, %{}).response

    assert {:error, :invalid_request} = setup_request(config, :arbitrary_function)
  end

  test "API delegates installation to the registered bridge, never directly to an adapter" do
    config = %{id: 71, provider: "relay_web"}

    event =
      Event.new(%{op: :installation, provider: "relay_web", config: config}, :channels,
        opts: [confidential: true, config: RelayConfig]
      )

    assert {:ok, %{bridge_received: 71, confidential: true}} =
             Api.handle_event(event, :channel_installation, %{}).response
  end

  defp setup_request(config, op, extra \\ %{}) do
    request =
      Map.merge(
        %{provider: config.provider, config: Map.take(config, [:id, :provider]), op: op},
        extra
      )

    Event.new(request, :channels, opts: [confidential: true])
    |> Api.handle_event(:channel_installation, %{})
    |> Map.fetch!(:response)
  end

  defp installation(config, base_url),
    do: setup_request(config, :installation, %{base_url: base_url})
end
