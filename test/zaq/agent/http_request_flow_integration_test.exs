defmodule Zaq.Agent.HttpRequestFlowIntegrationTest do
  @moduledoc """
  Real agent HTTP calls against a local API, including Engine-resolved credentials.
  Only the LLM and external API are doubles. Runtime database access requires
  the shared sandbox; policy and encrypted credentials roll back with the test.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Executor
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.{HttpCredentialProviderRef, OutboundHttpPolicy}
  alias Zaq.TestSupport.{IntegrationAgent, OpenAIStub, ToolCallingLLMStub}
  alias Zaq.Types.EncryptedString

  # QUERY is deferred until its real transport support is fixed: GitHub issue #729.
  @public_methods ~w(GET OPTIONS PUT DELETE)
  @methods @public_methods ++ ["POST"]
  @query %{"term" => "blue sky", "page" => 2, "active" => true}
  @wire_query %{"term" => "blue sky", "page" => "2", "active" => "true"}
  @body %{"message" => "API flow café", "count" => 3}

  setup do
    id = "http-flow-#{Ecto.UUID.generate()}"
    secret = "test-only-key-#{Ecto.UUID.generate()}"
    target = api_server(secret)
    port = URI.parse(target).port

    {:ok, _policy} =
      %OutboundHttpPolicy{}
      |> OutboundHttpPolicy.changeset(%{
        enabled: true,
        block_loopback: false,
        allowed_methods: @methods,
        allowed_ports: [port]
      })
      |> ZaqSystem.save_outbound_http_policy()

    credential = header_credential(id, secret)
    context = %{id: id, secret: secret, target: target, credential: credential}
    {:ok, Map.put(context, :agent, configured_agent(context))}
  end

  test "real HTTP methods and a stored header credential round-trip through the agent", context do
    assert %{rows: [[stored]]} =
             Repo.query!(
               "SELECT api_key FROM connect_credentials WHERE id = $1",
               [context.credential.id]
             )

    assert EncryptedString.encrypted?(stored)
    refute stored == context.secret

    for {method, body} <- [{"GET", nil}, {"OPTIONS", nil}, {"PUT", @body}, {"DELETE", nil}] do
      arguments =
        %{
          method: method,
          url: context.target <> "/" <> String.downcase(method),
          query: @query,
          body: body
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      assert_response(context, "Send #{method} to the test API", arguments, 200, false)
    end

    post = %{method: "POST", url: context.target <> "/post", query: @query, body: @body}
    assert_response(context, "Send POST to the test API without authentication", post, 401, false)
    authenticated_post = Map.put(post, :credential_id, context.credential.id)

    assert_response(
      context,
      "Send authenticated POST to the test API",
      authenticated_post,
      200,
      true
    )

    refute_received {:api_request, _}
    refute_received {:openai_request, _, _, _, _}
    refute_received {:llm_tool_call, _, _}
    refute_received {:llm_tool_result, _, _}
    refute_received {:llm_stub_error, _}
  end

  defp assert_response(context, message, arguments, status, authenticated?) do
    incoming = %Incoming{content: message, channel_id: context.id, provider: :web}
    outgoing = Executor.run(incoming, agent_id: to_string(context.agent.id), scope: context.id)
    assert_received {:llm_tool_call, "http_request", called_arguments}
    assert called_arguments == arguments |> Jason.encode!() |> Jason.decode!()
    refute Jason.encode!(called_arguments) =~ context.secret

    assert_received {:llm_tool_result, "http_request", result}
    assert result["ok"] == true, inspect(result)
    response = result["result"]
    path = URI.parse(arguments.url).path
    method = arguments.method

    expected = %{
      "method" => method,
      "path" => path,
      "query" => @wire_query,
      "body" => Map.get(arguments, :body),
      "authenticated" => authenticated?,
      "credential_header_count" => if(authenticated?, do: 1, else: 0)
    }

    assert_received {:api_request, observed}
    assert observed == expected
    assert response["status"] == status
    assert response["success"] == (status == 200)
    assert response["body"] == expected
    assert response["url"] == arguments.url
    assert response["truncated"] == false
    assert response["headers"]["content-type"] =~ "application/json"
    refute Jason.encode!(result) =~ context.secret
    assert outgoing.metadata.error == false
    assert outgoing.body == "HTTP result: #{Jason.encode!(result)}"
    refute outgoing.body =~ context.secret

    # Stream completion can precede the parent's ReAct state update. Wait for
    # the real terminal transition before sending the next incoming message.
    pid =
      Jido.AgentServer.whereis(
        Jido.registry_name(Zaq.Agent.Jido),
        "#{context.agent.name}:#{context.id}"
      )

    assert {:ok, %{status: :completed, result: answer}} =
             Jido.AgentServer.await_completion(pid,
               status_path: [:__strategy__, :status],
               result_path: [:__strategy__, :result],
               timeout: 5_000
             )

    assert answer == outgoing.body

    # The target also uses OpenAIStub's HTTP server, but has its own method/path.
    assert_received {:openai_request, ^method, ^path, query, body}
    assert URI.decode_query(query) == @wire_query
    assert decode_body(body) == Map.get(arguments, :body)

    for _ <- 1..2 do
      assert_received {:openai_request, "POST", "/v1/responses", _, llm_body}
      refute llm_body =~ context.secret
      names = llm_body |> Jason.decode!() |> Map.fetch!("tools") |> Enum.map(& &1["name"])
      assert names == ["http_request"]
    end
  end

  defp api_server(secret) do
    parent = self()

    handler = fn conn, body ->
      method = conn.method
      expected_path = "/v1/" <> String.downcase(method)

      unless method in @methods and conn.request_path == expected_path do
        raise "Unexpected API request method/path"
      end

      credential_headers = Plug.Conn.get_req_header(conn, "x-flow-api-key")
      authenticated? = credential_headers == [secret]

      payload = %{
        "method" => method,
        "path" => conn.request_path,
        "query" => URI.decode_query(conn.query_string),
        "body" => decode_body(body),
        "authenticated" => authenticated?,
        "credential_header_count" => length(credential_headers)
      }

      send(parent, {:api_request, payload})
      status = if method == "POST" and not authenticated?, do: 401, else: 200
      {status, payload}
    end

    {child, endpoint} = OpenAIStub.server(handler, parent)
    start_supervised!(Supervisor.child_spec(child, id: :target_api))
    endpoint
  end

  defp header_credential(id, secret) do
    {:ok, provider} =
      ZaqSystem.create_http_credential_provider(%{
        name: "Provider #{id}",
        auth_kind: "api_key",
        placement: "header",
        parameter_name: "x-flow-api-key",
        host_patterns: ["127.0.0.1"],
        enabled: true
      })

    {:ok, provider_ref} = HttpCredentialProviderRef.format(provider.id)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "Credential #{id}",
        provider: provider_ref,
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: secret
      })

    credential
  end

  defp configured_agent(context) do
    routes =
      Enum.map(@methods, fn method ->
        %{
          match: &String.contains?(&1, "Send #{method} to the test API"),
          tool: "http_request",
          arguments: fn _ -> arguments(context.target, method) end
        }
      end)

    secured = %{
      match: &String.contains?(&1, "Send authenticated POST to the test API"),
      tool: "http_request",
      arguments: fn _ ->
        context.target |> arguments("POST") |> Map.put(:credential_id, context.credential.id)
      end
    }

    {child, endpoint} =
      ToolCallingLLMStub.server([secured | routes],
        max_interactions: 6,
        final_response: fn %{tool_result: result} -> "HTTP result: #{Jason.encode!(result)}" end
      )

    start_supervised!(child)

    IntegrationAgent.create!(
      endpoint,
      context.id,
      "Send each requested HTTP call once and report its response.",
      ["general.http_request"]
    )
  end

  defp arguments(target, method) do
    args = %{method: method, url: target <> "/" <> String.downcase(method), query: @query}
    if method in ["PUT", "POST"], do: Map.put(args, :body, @body), else: args
  end

  defp decode_body(""), do: nil
  defp decode_body(body), do: Jason.decode!(body)
end
