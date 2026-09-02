defmodule Zaq.Agent.Tools.General.HttpRequestTest do
  use ExUnit.Case, async: true

  # Validation itself is covered in `Zaq.HttpRequestTest`. This file
  # covers the tool surface: schema, dispatch, and the build/send seam.

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.General.HttpRequest, as: Tool
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Channels.Api
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event
  alias Zaq.HttpRequest
  alias Zaq.System.OutboundHttpPolicy

  @response %{
    status: 200,
    success: true,
    headers: %{"content-type" => "application/json"},
    body: %{"id" => "thing_1"},
    truncated: false,
    url: "https://api.acme.test/v1/things"
  }

  defmodule StubNodeRouter do
    @moduledoc false
    def dispatch(%Event{request: request, opts: opts} = event) do
      send(self(), {:dispatch, Keyword.get(opts, :action), request, opts})

      %{
        event
        | response:
            {:ok,
             %{
               status: 200,
               success: true,
               headers: %{"content-type" => "application/json"},
               body: %{"id" => "thing_1"},
               truncated: false,
               url: "https://api.acme.test/v1/things"
             }}
      }
    end
  end

  defmodule ErrorNodeRouter do
    @moduledoc false
    def dispatch(%Event{} = event),
      do: %{event | response: {:error, {:transport_error, :econnrefused}}}
  end

  defmodule NeverRouter do
    @moduledoc false
    def dispatch(%Event{}), do: flunk("an invalid request was dispatched")
  end

  defp run(params, context \\ %{node_router: StubNodeRouter}) do
    with {:ok, validated} <- Tool.validate_params(params) do
      Tool.run(validated, context)
    end
  end

  defp base(overrides \\ %{}),
    do: Map.merge(%{method: "GET", url: "https://api.acme.test/v1/things"}, overrides)

  test "satisfies the workflow action contract" do
    assert :ok = Action.validate(Tool)
  end

  test "is registered in the tool registry under one key" do
    assert Registry.valid_tool_key?("general.http_request")
    assert {:ok, [Tool]} = Registry.resolve_modules(["general.http_request"])

    # The two-tool split is gone; the old keys must not resolve.
    refute Registry.valid_tool_key?("general.build_http_request")
    refute Registry.valid_tool_key?("general.execute_http_request")
  end

  describe "one turn: build then send" do
    test "returns the response from a single call" do
      assert {:ok, response} = run(base())
      assert response == @response
    end

    test "dispatches :http_request carrying a validated struct" do
      assert {:ok, _} =
               run(
                 base(%{
                   method: "POST",
                   headers: %{"X-Trace" => "abc"},
                   query: %{"page" => 2},
                   body: %{"sku" => "A1"},
                   timeout_ms: 5_000,
                   credential_id: 123
                 })
               )

      assert_received {:dispatch, :http_request, %{request: request}, opts}

      assert %HttpRequest{} = request
      assert opts == [action: :http_request]
      assert request.method == :post
      assert request.url == "https://api.acme.test/v1/things"
      assert request.headers == %{"x-trace" => "abc"}
      assert request.query == %{"page" => "2"}
      assert request.body == %{"sku" => "A1"}
      assert request.timeout_ms == 5_000
      assert request.credential_id == 123
    end

    test "a build failure short-circuits and never dispatches" do
      assert {:error, message} =
               run(base(%{url: "https://api.acme.test/x?a=1"}), %{node_router: NeverRouter})

      assert message =~ "must not carry a query string"
    end

    test "a rejected credential header never reaches the network" do
      assert {:error, message} =
               run(
                 base(%{headers: %{"Authorization" => "Bearer sk_live_secret"}}),
                 %{node_router: NeverRouter}
               )

      assert message =~ "literal authorization headers are not allowed"
      refute message =~ "sk_live_secret"
    end

    test "formats a dispatch error for the agent" do
      assert {:error, message} = run(base(), %{node_router: ErrorNodeRouter})

      assert message =~ "HTTP request failed"
      assert message =~ "transport_error"
    end
  end

  describe "schema and output" do
    test "the response passes output validation, string-keyed headers and all" do
      assert {:ok, response} = run(base())

      # The tool-call path validates the output against `output_schema`, so a
      # schema that rejects real response headers fails every live request.
      assert {:ok, validated} = Tool.validate_output(response)
      assert validated.headers == %{"content-type" => "application/json"}
    end

    test "output validation accepts a response with no headers" do
      assert {:ok, _} =
               Tool.validate_output(%{
                 status: 204,
                 success: true,
                 headers: %{},
                 body: "",
                 truncated: false,
                 url: "https://api.acme.test/v1/things"
               })
    end

    test "rejects an unknown method, a missing method, a missing url, and a bad format" do
      assert {:error, _} = Tool.validate_params(%{method: "TRACE", url: "https://a.t"})
      assert {:error, _} = Tool.validate_params(%{url: "https://a.t"})
      assert {:error, _} = Tool.validate_params(%{method: "GET"})

      assert {:error, _} =
               Tool.validate_params(%{
                 method: "POST",
                 url: "https://a.t",
                 body_format: "xml"
               })
    end

    test "params and output schemas are valid Zoi schemas" do
      assert Schema.schema_type(Tool.schema()) == :zoi
      assert Schema.schema_type(Tool.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(Tool.schema())
      assert :ok = Schema.validate_config_schema(Tool.output_schema())
    end

    test "method schema stays aligned with outbound HTTP policy support" do
      %{values: methods} = Tool.schema().fields[:method]

      assert Enum.map(methods, fn {method, method} -> method end) ==
               OutboundHttpPolicy.supported_methods()
    end

    test "there is no auth parameter or secret field to pass a credential through" do
      refute Keyword.has_key?(Tool.schema().fields, :auth)
      refute Keyword.has_key?(Tool.schema().fields, :api_key)
      refute Keyword.has_key?(Tool.schema().fields, :access_token)
      assert Keyword.has_key?(Tool.schema().fields, :credential_id)
    end
  end

  describe "through the real channels boundary" do
    defmodule LocalNodeRouter do
      @moduledoc false
      def dispatch(%Event{opts: opts} = event) do
        Api.handle_event(event, Keyword.fetch!(opts, :action), nil)
      end
    end

    defmodule MaliciousConfig do
      @moduledoc false

      def get(:zaq, Zaq.Channels.HttpClient, [], _opts) do
        [
          req_options: [
            plug: fn conn ->
              send(self(), {:unsafe_transport_override, conn.method})
              Plug.Conn.resp(conn, 204, "")
            end
          ]
        ]
      end
    end

    test "the tool does not forward transport config through event opts" do
      assert {:ok, @response} =
               run(base(), %{node_router: StubNodeRouter, config: MaliciousConfig})

      assert_received {:dispatch, :http_request, %{request: %HttpRequest{}}, opts}
      refute Keyword.has_key?(opts, :config)
    end

    test "Channels.Api rejects an :http_request event carrying a bare map" do
      event =
        Event.new(%{request: %{method: :get, url: "https://api.acme.test/x"}}, :channels,
          opts: [action: :http_request]
        )

      assert %Event{response: {:error, {:invalid_request, :unvalidated_spec}}} =
               LocalNodeRouter.dispatch(event)

      refute_received {:http, _method, _path}
    end

    test "Channels.Api rejects a bare map even when event opts carry transport overrides" do
      event =
        Event.new(%{request: %{method: :get, url: "https://api.acme.test/x"}}, :channels,
          opts: [
            action: :http_request,
            config: MaliciousConfig,
            req_options: [plug: fn conn -> conn end]
          ]
        )

      assert %Event{response: {:error, {:invalid_request, :unvalidated_spec}}} =
               LocalNodeRouter.dispatch(event)

      refute_received {:unsafe_transport_override, _method}
    end

    test "Channels.Api rejects an :http_request event with no spec" do
      event = Event.new(%{}, :channels, opts: [action: :http_request])

      assert %Event{response: {:error, {:invalid_request, :missing_http_request_spec}}} =
               LocalNodeRouter.dispatch(event)
    end
  end
end
