defmodule Zaq.Agent.MCP.Runtime do
  @moduledoc "Runtime helpers for MCP endpoint testing and registration."

  require Logger

  alias Anubis.MCP.Error, as: MCPError
  alias Jido.{MCP, MCP.Actions.ListTools, MCP.ClientPool}
  alias Zaq.Agent.MCP, as: MCPContext
  alias Zaq.Agent.MCP.Endpoint
  alias Zaq.Types.EncryptedString

  @test_endpoint_id :zaq_mcp_test
  @runtime_endpoint_prefix "mcp_"
  @max_runtime_endpoints 2000
  @atom_usage_threshold 0.85

  @spec runtime_endpoint_id(integer(), keyword()) :: {:ok, atom()} | {:error, term()}
  def runtime_endpoint_id(id, opts \\ [])

  def runtime_endpoint_id(id, opts) when is_integer(id) and id > 0 do
    atom_value = @runtime_endpoint_prefix <> Integer.to_string(id)

    case to_existing_atom(atom_value) do
      {:ok, endpoint_id} ->
        {:ok, endpoint_id}

      :error ->
        with :ok <- ensure_atom_budget(opts),
             :ok <- ensure_endpoint_cap(opts) do
          {:ok, String.to_atom(atom_value)}
        end
    end
  end

  def runtime_endpoint_id(_id, _opts), do: {:error, :invalid_endpoint_id}

  @spec db_endpoint_id(atom()) :: {:ok, integer()} | {:error, :invalid_runtime_endpoint_id}
  def db_endpoint_id(runtime_endpoint_id)
      when is_atom(runtime_endpoint_id) and runtime_endpoint_id != @test_endpoint_id do
    runtime_endpoint_id
    |> Atom.to_string()
    |> parse_runtime_endpoint_db_id()
  end

  def db_endpoint_id(_), do: {:error, :invalid_runtime_endpoint_id}

  @spec build_endpoint_attrs(atom(), Endpoint.t()) :: {:ok, map()} | {:error, term()}
  def build_endpoint_attrs(endpoint_id, %Endpoint{} = endpoint) when is_atom(endpoint_id) do
    with {:ok, transport} <- transport_for(endpoint) do
      {:ok,
       %{
         endpoint_id: endpoint_id,
         endpoint: %{
           transport: transport,
           client_info: %{"name" => "zaq", "version" => "1.0.0"},
           capabilities: %{},
           protocol_version: "2025-03-26",
           timeouts: %{request_ms: endpoint.timeout_ms || 5000}
         }
       }}
    end
  end

  @spec test_list_tools(Endpoint.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def test_list_tools(%Endpoint{} = endpoint, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, endpoint.timeout_ms || 5000)
    retry_sleep_ms = Keyword.get(opts, :retry_sleep_ms, 150)
    register_fn = Keyword.get(opts, :register_fn, &MCP.register_endpoint/1)
    unregister_fn = Keyword.get(opts, :unregister_fn, &MCP.unregister_endpoint/1)
    ensure_client_fn = Keyword.get(opts, :ensure_client_fn, &ClientPool.ensure_client/1)

    list_tools_fn =
      Keyword.get(opts, :list_tools_fn, fn endpoint_id, req_timeout ->
        ListTools.run(%{endpoint_id: endpoint_id, timeout: req_timeout}, %{})
      end)

    _ = safe_unregister(unregister_fn, @test_endpoint_id)

    try do
      with {:ok, runtime_endpoint} <- build_endpoint(@test_endpoint_id, endpoint),
           :ok <- normalize_register_result(register_fn.(runtime_endpoint)) do
        call_list_tools_with_retry(
          list_tools_fn,
          ensure_client_fn,
          @test_endpoint_id,
          timeout,
          retry_sleep_ms
        )
      end
    rescue
      e ->
        {:error, {:mcp_runtime_exception, Exception.message(e)}}
    catch
      kind, reason ->
        {:error, {:mcp_runtime_exit, {kind, reason}}}
    after
      _ = safe_unregister(unregister_fn, @test_endpoint_id)
    end
  end

  @spec build_endpoint(atom(), Endpoint.t()) :: {:ok, Jido.MCP.Endpoint.t()} | {:error, term()}
  def build_endpoint(endpoint_id, %Endpoint{} = endpoint) when is_atom(endpoint_id) do
    with {:ok, transport} <- transport_for(endpoint) do
      Jido.MCP.Endpoint.new(endpoint_id,
        transport: transport,
        client_info: %{"name" => "zaq", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2025-03-26",
        timeouts: %{request_ms: endpoint.timeout_ms || 5000}
      )
    end
  end

  defp transport_for(%Endpoint{type: "local"} = endpoint) do
    env =
      merge_secret_map(endpoint.environments, endpoint.secret_environments, :secret_environments)

    {:ok, {:stdio, command: endpoint.command, args: endpoint.args || [], env: env}}
  end

  defp transport_for(%Endpoint{type: "remote"} = endpoint) do
    with {:ok, %{base_url: base_url, mcp_path: mcp_path}} <- parse_url(endpoint.url) do
      headers = merge_secret_map(endpoint.headers, endpoint.secret_headers, :secret_headers)

      {:ok, {:streamable_http, base_url: base_url, mcp_path: mcp_path, headers: headers}}
    end
  end

  defp transport_for(_endpoint), do: {:error, :unsupported_type}

  defp parse_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if is_nil(uri.scheme) or
         is_nil(uri.host) do
      {:error, :invalid_url}
    else
      base_url = "#{uri.scheme}://#{uri.host}#{port_segment(uri)}"
      path = if is_binary(uri.path) and uri.path != "", do: uri.path, else: "/mcp"
      {:ok, %{base_url: base_url, mcp_path: path}}
    end
  end

  defp parse_url(_), do: {:error, :invalid_url}

  defp parse_runtime_endpoint_db_id(@runtime_endpoint_prefix <> id_text) do
    case Integer.parse(id_text) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_runtime_endpoint_id}
    end
  end

  defp parse_runtime_endpoint_db_id(_), do: {:error, :invalid_runtime_endpoint_id}

  defp to_existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp ensure_atom_budget(opts) do
    atom_count_fn = Keyword.get(opts, :atom_count_fn, fn -> :erlang.system_info(:atom_count) end)
    atom_limit_fn = Keyword.get(opts, :atom_limit_fn, fn -> :erlang.system_info(:atom_limit) end)
    atom_count = atom_count_fn.()
    atom_limit = atom_limit_fn.()

    usage = if atom_limit > 0, do: atom_count / atom_limit, else: 1.0

    if usage >= @atom_usage_threshold do
      {:error, {:atom_budget_exceeded, %{atom_count: atom_count, atom_limit: atom_limit}}}
    else
      :ok
    end
  end

  defp ensure_endpoint_cap(opts) do
    endpoint_count_fn =
      Keyword.get(opts, :endpoint_count_fn, fn -> MCPContext.list_mcp_endpoints() |> length() end)

    endpoint_count = endpoint_count_fn.()

    if endpoint_count >= @max_runtime_endpoints do
      {:error, {:endpoint_cap_reached, %{max: @max_runtime_endpoints, current: endpoint_count}}}
    else
      :ok
    end
  end

  defp port_segment(%URI{port: nil}), do: ""

  defp port_segment(%URI{scheme: "http", port: 80}), do: ""
  defp port_segment(%URI{scheme: "https", port: 443}), do: ""
  defp port_segment(%URI{port: port}), do: ":#{port}"

  defp merge_secret_map(plain, secrets, secret_field) do
    plain = ensure_string_map(plain)
    secrets = ensure_string_map(secrets)

    decrypted_secrets =
      Enum.reduce(secrets, %{}, fn {key, value}, acc ->
        case EncryptedString.decrypt(value) do
          {:ok, decrypted} ->
            Map.put(acc, key, decrypted)

          {:error, reason} ->
            Logger.warning(
              "MCP secret decryption failed for #{secret_field} key=#{inspect(key)}: #{inspect(reason)}"
            )

            acc

          other ->
            Logger.warning(
              "MCP secret decryption failed for #{secret_field} key=#{inspect(key)}: #{inspect(other)}"
            )

            acc
        end
      end)

    Map.merge(plain, decrypted_secrets)
  end

  defp ensure_string_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) and is_binary(v) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end

  defp ensure_string_map(_), do: %{}

  defp normalize_register_result({:ok, _value}), do: :ok
  defp normalize_register_result(:ok), do: :ok
  defp normalize_register_result(other), do: other

  defp call_list_tools_with_retry(
         list_tools_fn,
         ensure_client_fn,
         endpoint_id,
         timeout,
         retry_sleep_ms
       ) do
    first = safe_list_tools_call(list_tools_fn, ensure_client_fn, endpoint_id, timeout)

    cond do
      capabilities_not_ready_result?(first) ->
        Process.sleep(retry_sleep_ms)
        safe_list_tools_call(list_tools_fn, ensure_client_fn, endpoint_id, timeout)

      transient_client_call_exit?(first) ->
        Process.sleep(retry_sleep_ms)
        safe_list_tools_call(list_tools_fn, ensure_client_fn, endpoint_id, timeout)

      true ->
        first
    end
  end

  defp safe_list_tools_call(list_tools_fn, ensure_client_fn, endpoint_id, timeout) do
    monitor_ref = maybe_monitor_client(ensure_client_fn, endpoint_id)

    try do
      list_tools_fn.(endpoint_id, timeout)
    rescue
      e -> {:error, {:mcp_runtime_exception, Exception.message(e)}}
    catch
      :exit, reason -> normalize_call_exit_error(reason, monitor_ref)
      kind, reason -> {:error, {:mcp_runtime_exit, {kind, reason}}}
    after
      cleanup_monitor(monitor_ref)
    end
  end

  defp maybe_monitor_client(ensure_client_fn, endpoint_id) do
    case ensure_client_fn.(endpoint_id) do
      {:ok, _endpoint, %{client: client_name}} ->
        case resolve_name(client_name) do
          pid when is_pid(pid) -> Process.monitor(pid)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_call_exit_error(reason, monitor_ref) do
    case extract_down_reason(monitor_ref) do
      nil ->
        {:error, {:mcp_runtime_call_exit, reason}}

      down_reason ->
        {:error,
         %{
           status: :error,
           type: :transport,
           message: "MCP client transport failure",
           details: down_reason
         }}
    end
  end

  defp extract_down_reason(nil), do: nil

  defp extract_down_reason(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, down_reason} -> down_reason
    after
      25 -> nil
    end
  end

  defp cleanup_monitor(nil), do: :ok

  defp cleanup_monitor(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp capabilities_not_ready_result?(result) do
    case result do
      {:error, %{details: %MCPError{reason: :internal_error, data: data}}} when is_map(data) ->
        capability_message?(Map.get(data, :message) || Map.get(data, "message"))

      {:error, %{details: %MCPError{reason: :internal_error, message: message}}} ->
        capability_message?(message)

      {:error, %{details: details}} when is_map(details) ->
        capability_message?(Map.get(details, :message) || Map.get(details, "message"))

      {:error, %{message: message}} ->
        capability_message?(message)

      {:error, reason} ->
        capability_message_from_text?(inspect(reason))

      _ ->
        false
    end
  end

  defp capability_message?(message) when is_binary(message),
    do: message == "Server capabilities not set"

  defp capability_message?(_), do: false

  defp capability_message_from_text?(text) when is_binary(text) do
    String.contains?(text, "Server capabilities not set")
  end

  defp capability_message_from_text?(_), do: false

  defp transient_client_call_exit?({:error, {:mcp_runtime_call_exit, reason}}) do
    rendered = inspect(reason)

    String.contains?(rendered, "{GenServer, :call") and
      (String.contains?(rendered, ":shutdown") or String.contains?(rendered, ":noproc"))
  end

  defp transient_client_call_exit?(_), do: false

  defp safe_unregister(unregister_fn, endpoint_id) do
    case unregister_fn.(endpoint_id) do
      {:error, :unknown_endpoint} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp resolve_name(name) when is_tuple(name), do: GenServer.whereis(name)
  defp resolve_name(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_name(name) when is_pid(name), do: name
  defp resolve_name(_), do: nil
end
