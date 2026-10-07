defmodule Zaq.Channels.Web.RuntimeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Supervisor, WebBridge}
  alias Zaq.Channels.Web.{Command, Context, Runtime}
  alias Zaq.Engine.ChannelConfig

  defmodule Builder do
    @behaviour Zaq.Channels.Web.WidgetAdapter

    @impl true
    def build(config, hooks) do
      send(config.settings["test_pid"], {:hooks, hooks})

      if config.settings["fail"],
        do: {:error, :fixture_failure},
        else:
          {:ok, {%{id: :widget_state, start: {Agent, :start_link, [fn -> config.id end]}}, []}}
    end

    @impl true
    def embed_script(widget_id, base_url),
      do: {:ok, "<script src=\"#{base_url}/widget.js\" data-widget-id=\"#{widget_id}\"></script>"}
  end

  defmodule InvalidSnippetBuilder do
    def embed_script(_, _), do: {:ok, %{secret: "not a snippet"}}
  end

  defmodule RaisingSnippetBuilder do
    def embed_script(_, _), do: raise("secret failure details")
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :web_widget, %{bridge: WebBridge, adapter: Builder})
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

  test "runtime construction derives widget ID and supplies only the shared contracts", %{
    config: config
  } do
    assert :ok = WebBridge.start_runtime(config)
    assert_receive {:hooks, hooks}
    assert hooks.widget_id == config.id
    assert hooks.message == Zaq.Channels.Web.Message
    assert hooks.command == Zaq.Channels.Web.Command
    assert hooks.context == Zaq.Channels.Web.Context
    assert hooks.sink_mfa == {Runtime, :from_listener, [%{id: config.id}]}
    assert hooks.allowed_domains == ["https://parent.example.test"]
    refute Map.has_key?(hooks, :stylesheet_url)
    assert {:ok, %{state_pid: pid}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.start_runtime(config)
    assert {:ok, %{state_pid: ^pid}} = Supervisor.lookup_runtime("web_widget_#{config.id}")
    assert :ok = WebBridge.stop_runtime(config)
    refute Process.alive?(pid)
  end

  test "adapter configuration reports readiness and running runtime", %{config: config} do
    assert {:ok, %{available?: true, runtime: :not_running}} = Runtime.status(config.id)
    assert :ok = WebBridge.start_runtime(config)
    assert {:ok, %{available?: true, runtime: :running}} = Runtime.status(config.id)
    assert :ok = WebBridge.stop_runtime(config)
    assert {:ok, %{available?: true, runtime: :not_running}} = Runtime.status(config.id)
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
    assert {:ok, snippet} = Runtime.embed_script(config.id, "https://zaq.example.test")

    assert snippet ==
             "<script src=\"https://zaq.example.test/widget.js\" data-widget-id=\"#{config.id}\"></script>"

    assert {:error, :invalid_widget_embed_request} =
             Runtime.embed_script(0, "https://zaq.example.test")

    assert {:error, :invalid_widget_embed_request} = Runtime.embed_script(config.id, nil)
  end

  test "missing, malformed and raising snippet callbacks return bounded errors", %{config: config} do
    channels = Application.get_env(:zaq, :channels)

    for {builder, error} <- [
          {nil, :widget_embed_not_configured},
          {InvalidSnippetBuilder, :invalid_widget_embed_script},
          {RaisingSnippetBuilder, :widget_embed_failed}
        ] do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :web_widget, %{adapter: builder})
      )

      assert {:error, ^error} = Runtime.embed_script(config.id, "https://zaq.example.test")
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
    assert {:error, :widget_runtime_not_configured} = WebBridge.start_runtime(config)
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
    assert {:error, :unauthorized} = Runtime.from_listener(config, command, context: context)
    assert {:error, :unauthorized} = Runtime.from_listener(config, %{context: context}, [])
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
end
