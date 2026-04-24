defmodule Zaq.Agent.MCP.RuntimeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.MCP.Endpoint
  alias Zaq.Agent.MCP.Runtime
  alias Zaq.Types.EncryptedString

  setup do
    prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
    end)

    :ok
  end

  test "build_endpoint builds local stdio endpoint and decrypts secret env vars" do
    {:ok, encrypted_token} = EncryptedString.encrypt("top-secret")

    endpoint = %Endpoint{
      name: "Local",
      type: "local",
      status: "enabled",
      timeout_ms: 4321,
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem"],
      environments: %{"HOME" => "/tmp"},
      secret_environments: %{"API_TOKEN" => encrypted_token}
    }

    assert {:ok, runtime_endpoint} = Runtime.build_endpoint(:local_test, endpoint)
    assert runtime_endpoint.id == :local_test
    assert runtime_endpoint.timeouts.request_ms == 4321

    assert {:stdio, opts} = runtime_endpoint.transport
    assert opts[:command] == "npx"
    assert opts[:args] == ["-y", "@modelcontextprotocol/server-filesystem"]
    assert opts[:env]["HOME"] == "/tmp"
    assert opts[:env]["API_TOKEN"] == "top-secret"
  end

  test "build_endpoint builds remote streamable_http endpoint and decrypts secret headers" do
    {:ok, encrypted_auth} = EncryptedString.encrypt("Bearer abc")

    endpoint = %Endpoint{
      name: "Remote",
      type: "remote",
      status: "enabled",
      timeout_ms: 5000,
      url: "https://example.com:8443/mcp",
      headers: %{"X-App" => "zaq"},
      secret_headers: %{"Authorization" => encrypted_auth}
    }

    assert {:ok, runtime_endpoint} = Runtime.build_endpoint(:remote_test, endpoint)
    assert {:streamable_http, opts} = runtime_endpoint.transport
    assert opts[:base_url] == "https://example.com:8443"
    assert opts[:mcp_path] == "/mcp"
    assert opts[:headers]["X-App"] == "zaq"
    assert opts[:headers]["Authorization"] == "Bearer abc"
  end

  test "build_endpoint returns error for invalid remote url" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 5000, url: "not a valid url"}
    assert {:error, :invalid_url} = Runtime.build_endpoint(:remote_bad, endpoint)
  end

  test "build_endpoint returns unsupported type error" do
    endpoint = %Endpoint{type: "other", timeout_ms: 5000}
    assert {:error, :unsupported_type} = Runtime.build_endpoint(:unsupported, endpoint)
  end

  test "build_endpoint normalizes default port and default path for remote urls" do
    endpoint = %Endpoint{type: "remote", timeout_ms: nil, url: "https://example.com:443"}

    assert {:ok, runtime_endpoint} = Runtime.build_endpoint(:remote_default_port, endpoint)
    assert {:streamable_http, opts} = runtime_endpoint.transport
    assert opts[:base_url] == "https://example.com"
    assert opts[:mcp_path] == "/mcp"
    assert runtime_endpoint.timeouts.request_ms == 5000
  end

  test "build_endpoint supports http default port and nil port urls" do
    endpoint_http = %Endpoint{type: "remote", timeout_ms: 5000, url: "http://example.com:80/mcp"}
    endpoint_nil = %Endpoint{type: "remote", timeout_ms: 5000, url: "http://example.org/mcp"}

    assert {:ok, runtime_http} = Runtime.build_endpoint(:remote_http_port, endpoint_http)
    assert {:streamable_http, http_opts} = runtime_http.transport
    assert http_opts[:base_url] == "http://example.com"

    assert {:ok, runtime_nil} = Runtime.build_endpoint(:remote_nil_port, endpoint_nil)
    assert {:streamable_http, nil_opts} = runtime_nil.transport
    assert nil_opts[:base_url] == "http://example.org"
  end

  test "build_endpoint returns invalid url for non-binary remote url" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 5000, url: nil}
    assert {:error, :invalid_url} = Runtime.build_endpoint(:remote_non_binary, endpoint)
  end

  test "build_endpoint ignores invalid secret values and non-string keys" do
    endpoint = %Endpoint{
      type: "remote",
      timeout_ms: 5000,
      url: "http://localhost:8000",
      headers: %{"X-App" => "zaq", :bad => "x"},
      secret_headers: %{"Authorization" => "not-encrypted", "Token" => "enc:bad"}
    }

    assert {:ok, runtime_endpoint} = Runtime.build_endpoint(:remote_filtered_headers, endpoint)
    assert {:streamable_http, opts} = runtime_endpoint.transport
    assert opts[:headers]["X-App"] == "zaq"
    assert opts[:headers]["Authorization"] == "not-encrypted"
    refute Map.has_key?(opts[:headers], :bad)
    refute Map.has_key?(opts[:headers], "Token")
  end

  test "test_list_tools registers, calls list tools, and unregisters endpoint" do
    endpoint = %Endpoint{
      type: "remote",
      timeout_ms: 2000,
      url: "http://localhost:8000/mcp",
      headers: %{},
      secret_headers: %{}
    }

    register_fn = fn runtime_endpoint ->
      send(self(), {:registered, runtime_endpoint.id})
      :ok
    end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      :ok
    end

    list_tools_fn = fn endpoint_id, timeout ->
      send(self(), {:listed_tools, endpoint_id, timeout})
      {:ok, %{status: :ok, endpoint: endpoint_id}}
    end

    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               timeout: 1234,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )

    assert_received {:registered, :zaq_mcp_test}
    assert_received {:listed_tools, :zaq_mcp_test, 1234}
    assert_received {:unregistered, :zaq_mcp_test}
  end

  test "test_list_tools catches outer rescue from register and still unregisters" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> raise "register boom" end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      :ok
    end

    assert {:error, {:mcp_runtime_exception, _}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn
             )

    assert_received {:unregistered, :zaq_mcp_test}
  end

  test "test_list_tools handles default list_tools function path" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 1000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> {:ok, :registered} end
    unregister_fn = fn _endpoint_id -> :ok end
    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert {:error, _} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn
             )
  end

  test "test_list_tools catches non-exit throw from list_tools function" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 1000, url: "http://localhost:8000/mcp"}
    register_fn = fn _runtime_endpoint -> :ok end
    unregister_fn = fn _endpoint_id -> :ok end
    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end
    list_tools_fn = fn _endpoint_id, _timeout -> throw(:boom) end

    assert {:error, {:mcp_runtime_exit, {:throw, :boom}}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )
  end

  test "test_list_tools retries once when capabilities are not ready" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> :ok end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      :ok
    end

    first_error =
      {:error,
       %{
         message: "Internal error",
         status: :error,
         type: :protocol,
         details: "Server capabilities not set"
       }}

    list_tools_fn = fn endpoint_id, _timeout ->
      send(self(), {:listed_tools, endpoint_id})

      case Process.get(:listed_once) do
        true ->
          {:ok, %{status: :ok, endpoint: endpoint_id}}

        _ ->
          Process.put(:listed_once, true)
          first_error
      end
    end

    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn,
               retry_sleep_ms: 1
             )

    assert_received {:listed_tools, :zaq_mcp_test}
    assert_received {:listed_tools, :zaq_mcp_test}
    assert_received {:unregistered, :zaq_mcp_test}
  end

  test "test_list_tools retries after transient client call exit and returns second error" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> :ok end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      :ok
    end

    unauthorized_error =
      {:error,
       %{
         message: "Send Failure",
         status: :error,
         type: :transport,
         details:
           "{:http_error, 401, \"unauthorized: unauthorized: AuthenticateToken authentication failed\\n\"}"
       }}

    list_tools_fn = fn endpoint_id, _timeout ->
      send(self(), {:listed_tools, endpoint_id})

      case Process.get(:listed_once_call_exit) do
        true ->
          unauthorized_error

        _ ->
          Process.put(:listed_once_call_exit, true)
          exit({:shutdown, {GenServer, :call, [:client, {:operation, :list_tools}, 6000]}})
      end
    end

    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert ^unauthorized_error =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn,
               retry_sleep_ms: 1
             )

    assert_received {:listed_tools, :zaq_mcp_test}
    assert_received {:listed_tools, :zaq_mcp_test}
    assert_received {:unregistered, :zaq_mcp_test}
  end

  test "test_list_tools converts raised errors and still unregisters endpoint" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> :ok end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      :ok
    end

    list_tools_fn = fn _endpoint_id, _timeout -> raise "boom" end

    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert {:error, {:mcp_runtime_exception, _message}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )

    assert_received {:unregistered, :zaq_mcp_test}
  end

  test "test_list_tools clears stale endpoint before registering" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn runtime_endpoint ->
      send(self(), {:registered, runtime_endpoint.id})
      :ok
    end

    unregister_fn = fn endpoint_id ->
      send(self(), {:unregistered, endpoint_id})
      {:error, :unknown_endpoint}
    end

    list_tools_fn = fn endpoint_id, _timeout -> {:ok, %{status: :ok, endpoint: endpoint_id}} end

    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )

    assert_received {:unregistered, :zaq_mcp_test}
    assert_received {:registered, :zaq_mcp_test}
  end

  test "test_list_tools returns register errors without calling list tools" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> {:error, :register_failed} end
    unregister_fn = fn _endpoint_id -> :ok end

    list_tools_fn = fn _endpoint_id, _timeout ->
      send(self(), :listed)
      {:ok, %{status: :ok}}
    end

    assert {:error, :register_failed} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               list_tools_fn: list_tools_fn
             )

    refute_received :listed
  end

  test "test_list_tools catches throw from register function" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    register_fn = fn _runtime_endpoint -> throw(:register_throw) end
    unregister_fn = fn _endpoint_id -> :ok end

    assert {:error, {:mcp_runtime_exit, {:throw, :register_throw}}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn
             )
  end

  test "test_list_tools handles transport down reason from monitored client" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}
    client = spawn(fn -> receive do :stop -> :ok end end)

    list_tools_fn = fn _endpoint_id, _timeout ->
      send(client, :stop)
      Process.sleep(10)
      exit({:shutdown, {GenServer, :call, [:client, {:operation, :list_tools}, 6000]}})
    end

    ensure_client_fn = fn _endpoint_id -> {:ok, :endpoint, %{client: client}} end
    register_fn = fn _runtime_endpoint -> :ok end
    unregister_fn = fn _endpoint_id -> :ok end

    assert {:error, %{type: :transport, message: "MCP client transport failure", details: :normal}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn,
               retry_sleep_ms: 1
             )
  end

  test "test_list_tools returns call exit when monitored client stays alive" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}
    client = spawn(fn -> Process.sleep(200) end)

    list_tools_fn = fn _endpoint_id, _timeout ->
      exit({:shutdown, {GenServer, :call, [:client, {:operation, :list_tools}, 6000]}})
    end

    ensure_client_fn = fn _endpoint_id -> {:ok, :endpoint, %{client: client}} end
    register_fn = fn _runtime_endpoint -> :ok end
    unregister_fn = fn _endpoint_id -> :ok end

    assert {:error, {:mcp_runtime_call_exit, _}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn,
               retry_sleep_ms: 1
             )
  end

  test "test_list_tools with non-pid ensure_client name still calls list tools" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}
    register_fn = fn _runtime_endpoint -> :ok end
    unregister_fn = fn _endpoint_id -> :ok end

    list_tools_fn = fn endpoint_id, _timeout -> {:ok, %{status: :ok, endpoint: endpoint_id}} end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: fn _ -> {:ok, :endpoint, %{client: :unknown_name}} end,
               list_tools_fn: list_tools_fn
             )

    assert {:error, {:mcp_runtime_exception, _}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: fn _ -> {:ok, :endpoint, %{client: {:via, Registry, {:x, :y}}}} end,
               list_tools_fn: list_tools_fn
             )

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: fn _ -> {:ok, :endpoint, %{client: 123}} end,
               list_tools_fn: list_tools_fn
             )
  end

  test "test_list_tools succeeds when unregister raises" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}

    unregister_fn = fn _endpoint_id -> raise "unregister failed" end
    register_fn = fn _runtime_endpoint -> :ok end
    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end
    list_tools_fn = fn endpoint_id, _timeout -> {:ok, %{status: :ok, endpoint: endpoint_id}} end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )
  end

  test "test_list_tools ignores thrown unregister function" do
    endpoint = %Endpoint{type: "remote", timeout_ms: 2000, url: "http://localhost:8000/mcp"}
    register_fn = fn _runtime_endpoint -> :ok end
    ensure_client_fn = fn _endpoint_id -> {:error, :no_client} end
    list_tools_fn = fn endpoint_id, _timeout -> {:ok, %{status: :ok, endpoint: endpoint_id}} end
    unregister_fn = fn _endpoint_id -> throw(:unregister_throw) end

    assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
             Runtime.test_list_tools(endpoint,
               register_fn: register_fn,
               unregister_fn: unregister_fn,
               ensure_client_fn: ensure_client_fn,
               list_tools_fn: list_tools_fn
             )
  end
end
