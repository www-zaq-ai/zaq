defmodule Zaq.Channels.WidgetDevModeTest do
  use ExUnit.Case, async: true, group: :widget_vm_startup

  test "development flag supplies only the widget partitioning default" do
    script = """
    defmodule DevAdapter do
      def infrastructure_child_specs(opts) do
        send(self(), {:options, opts})
        {:ok, []}
      end
    end
    defmodule DevConfig do
      def get(:zaq, :channels, _), do: %{web_widget: %{adapter: DevAdapter}, other: %{adapter: DevAdapter}}
    end
    options = fn provider, extras ->
      {:ok, {nil, []}} = Zaq.Channels.WebBridge.build_runtime_specs({:provider, provider}, [config: DevConfig] ++ extras)
      receive do
        {:options, opts} -> opts
      after
        0 -> raise("adapter options missing")
      end
    end
    for value <- [nil, "", "false", "1", "TRUE", "unexpected"] do
      if value, do: System.put_env("WIDGET_DEV_MODE", value), else: System.delete_env("WIDGET_DEV_MODE")
      opts = options.(:web_widget, [])
      unless opts[:session] == nil, do: raise("unexpected implicit HTTP mode")
    end
    System.put_env("WIDGET_DEV_MODE", "true")
    opts = options.(:web_widget, [])
    unless opts[:session] == [partitioned: false], do: raise("development flag not delivered")
    unless opts[:scope] == "/channels" and opts[:pubsub_server] == Zaq.PubSub,
      do: raise("normal host defaults changed")
    unless options.(:other, [])[:session] == nil, do: raise("flag escaped widget provider")
    explicit = [partitioned: true, secure: true]
    unless options.(:web_widget, adapter_options: %{web_widget: [session: explicit]})[:session] == explicit,
      do: raise("explicit session policy overwritten")
    opts = options.(:web_widget, host_options: [session: [secure: true]])
    unless opts[:session][:secure] == true and opts[:session][:partitioned] == false,
      do: raise("explicit secure policy lost")
    IO.puts("development options verified")
    """

    {output, status} = run_vm(script)
    assert status == 0, output
    assert output =~ "development options verified"
  end

  test "ordinary development startup permits HTTP Lax sessions but preserves security checks" do
    script = """
    endpoint = Application.fetch_env!(:zaq, ZaqWeb.Endpoint)
    Application.put_env(:zaq, ZaqWeb.Endpoint, Keyword.merge(endpoint,
      server: true, http: [ip: {127, 0, 0, 1}, port: 0], https: false, force_ssl: false,
      code_reloader: false))
    {:ok, _} = Application.ensure_all_started(:zaq)
    {:ok, config} = WebWidget.Configuration.fetch()
    unless config.session[:partitioned] == false and config.proxy == nil,
      do: raise("ordinary boot did not deliver HTTP development option")
    widget = %{
      id: 987654321, name: "HTTP development fixture", provider: "web_widget", enabled: true,
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      settings: Zaq.ConnectorConfig.WidgetSettings.defaults()
        |> Map.put("same_site", "Lax")
        |> Map.put("allowed_domains", ["http://localhost:4100"])
    }
    :ok = Zaq.Channels.WebBridge.start_runtime(widget)
    {:ok, {_, port}} = ZaqWeb.Endpoint.server_info(:http)
    url = "http://localhost:" <> Integer.to_string(port) <> "/channels/widget/987654321"
    options = [retry: false, headers: [{"origin", "http://localhost:" <> Integer.to_string(port)}]]
    page = Req.get!(url, options)
    unless page.status == 200, do: raise("HTTP widget page unavailable")
    [csp] = Req.Response.get_header(page, "content-security-policy")
    unless csp =~ "frame-ancestors http://localhost:4100", do: raise("embedding allowlist lost")
    session = Req.get!(url <> "/session", options)
    unless session.status == 200, do: raise("HTTP session unavailable")
    [cookie] = Req.Response.get_header(session, "set-cookie")
    cookie = String.downcase(cookie)
    unless cookie =~ "samesite=lax" and cookie =~ "httponly", do: raise("cookie policy lost")
    if cookie =~ "partitioned" or cookie =~ "; secure", do: raise("HTTP development cookie unusable")
    foreign = Req.get!(url <> "/session", retry: false, headers: [{"origin", "http://evil.example"}])
    unless foreign.status == 403 and Req.Response.get_header(foreign, "set-cookie") == [],
      do: raise("origin rejection lost")
    {:error, :unauthorized} = WebWidget.Runtime.authenticate("987654321", "invalid", "page")
    {:ok, %{status: :ok, verification: %{session_handshake: :verified}}} =
      Zaq.Channels.WebBridge.channel_ingress_status(widget)
    secure = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    :ok = Zaq.Channels.WebBridge.sync_runtime(widget, secure)
    rejected = Req.get!(url <> "/session", options)
    unless rejected.status == 503 and rejected.body == "https_required" and
      Req.Response.get_header(rejected, "set-cookie") == [],
      do: raise("SameSite None silently downgraded")
    IO.puts("ordinary HTTP development boot verified")
    """

    {output, status} = run_vm(script, "true")
    assert status == 0, output
    assert output =~ "ordinary HTTP development boot verified"
  end

  defp run_vm(script, flag \\ nil) do
    System.cmd("mix", ["run", "--no-start", "-e", script],
      env: [
        {"MIX_ENV", "test"},
        {"WIDGET_DEV_MODE", flag},
        {"ROLES", "channels,bo"},
        {"PHX_SERVER", nil},
        {"E2E", nil},
        {"ERL_FLAGS", "+S 2:2"}
      ],
      stderr_to_stdout: true
    )
  end
end
