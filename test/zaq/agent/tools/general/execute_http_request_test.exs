defmodule Zaq.Agent.Tools.General.ExecuteHttpRequestTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.General.ExecuteHttpRequest
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Channels.Api
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event

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
      do: %{event | response: {:error, {:private_host_not_allowed, "127.0.0.1"}}}
  end

  defp request_spec do
    %{
      method: :get,
      url: "https://api.acme.test/v1/things",
      headers: %{},
      query: %{},
      body: nil,
      body_format: "json"
    }
  end

  test "satisfies the workflow action contract" do
    assert :ok = Action.validate(ExecuteHttpRequest)
  end

  test "is registered in the tool registry" do
    assert Registry.valid_tool_key?("general.execute_http_request")

    assert {:ok, [ExecuteHttpRequest]} =
             Registry.resolve_modules(["general.execute_http_request"])
  end

  test "dispatches :http_request to channels with the spec and timeout" do
    assert {:ok, response} =
             ExecuteHttpRequest.run(
               %{request: request_spec(), timeout_ms: 5_000},
               %{node_router: StubNodeRouter}
             )

    assert response == @response

    assert_received {:dispatch, :http_request, %{request: spec}, opts}
    assert spec == request_spec()
    assert Keyword.get(opts, :timeout_ms) == 5_000
  end

  test "the response passes output validation, string-keyed headers and all" do
    assert {:ok, response} =
             ExecuteHttpRequest.run(
               %{request: request_spec(), timeout_ms: 5_000},
               %{node_router: StubNodeRouter}
             )

    # The tool-call path validates the output against `output_schema`, so a
    # schema that rejects real response headers fails every live request.
    assert {:ok, validated} = ExecuteHttpRequest.validate_output(response)
    assert validated.headers == %{"content-type" => "application/json"}
  end

  test "output validation accepts a response with no headers" do
    assert {:ok, _} =
             ExecuteHttpRequest.validate_output(%{
               status: 204,
               success: true,
               headers: %{},
               body: "",
               truncated: false,
               url: "https://api.acme.test/v1/things"
             })
  end

  test "formats a dispatch error for the agent" do
    assert {:error, message} =
             ExecuteHttpRequest.run(
               %{request: request_spec(), timeout_ms: 30_000},
               %{node_router: ErrorNodeRouter}
             )

    assert message =~ "HTTP request failed"
    assert message =~ "private_host_not_allowed"
  end

  test "rejects a request that is not a map" do
    assert {:error, message} =
             ExecuteHttpRequest.run(%{request: "https://api.acme.test"}, %{})

    assert message =~ "must be the map returned by build_http_request"
  end

  test "requires a request" do
    assert {:error, _} = ExecuteHttpRequest.validate_params(%{})
  end

  describe "through the real channels boundary" do
    defmodule LocalNodeRouter do
      @moduledoc false
      def dispatch(%Event{opts: opts} = event),
        do: Api.handle_event(event, Keyword.fetch!(opts, :action), nil)
    end

    defmodule StubHttp do
      @moduledoc false
      def request(spec, opts) do
        send(self(), {:http, spec, opts})
        {:ok, %{status: 204, success: true, headers: %{}, body: "", truncated: false, url: "u"}}
      end
    end

    test "Channels.Api routes :http_request to the http module with the spec" do
      event =
        Event.new(%{request: request_spec()}, :channels,
          opts: [action: :http_request, timeout_ms: 1_000, http_module: StubHttp]
        )

      assert %Event{response: {:ok, %{status: 204}}} = LocalNodeRouter.dispatch(event)

      assert_received {:http, spec, opts}
      assert spec == request_spec()
      assert Keyword.get(opts, :timeout_ms) == 1_000
    end

    test "Channels.Api rejects an :http_request event with no spec" do
      event = Event.new(%{}, :channels, opts: [action: :http_request])

      assert %Event{response: {:error, {:invalid_request, :missing_http_request_spec}}} =
               LocalNodeRouter.dispatch(event)
    end

    defmodule EndToEndRouter do
      @moduledoc false
      def dispatch(%Event{opts: opts} = event) do
        event = %{event | opts: Keyword.put(opts, :http_module, StubHttp)}
        Api.handle_event(event, Keyword.fetch!(opts, :action), nil)
      end
    end

    test "the tool reaches the real Api clause end to end" do
      assert {:ok, %{status: 204}} =
               ExecuteHttpRequest.run(
                 %{request: request_spec(), timeout_ms: 1_000},
                 %{node_router: EndToEndRouter}
               )

      assert_received {:http, _spec, _opts}
    end
  end
end
