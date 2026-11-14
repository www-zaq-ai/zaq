defmodule Zaq.Engine.Extension.Client do
  @moduledoc """
  Calls the local Extension gateway Health RPC over mutually authenticated TLS/UDS.
  Transport failures are reduced to safe reason codes; health does not confer entitlement.
  """

  alias GRPC.Client.Connection
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{Gateway, HealthRequest, HealthResponse}

  @required [:socket_path, :ca_cert, :client_cert, :client_key, :server_name]
  @path_keys [:socket_path, :ca_cert, :client_cert, :client_key]

  @doc "Returns validated node-local connection settings, or an optional/configuration error."
  @spec settings(keyword()) :: {:ok, keyword()} | {:error, atom()}
  def settings(opts \\ []) do
    settings =
      Keyword.get_lazy(opts, :settings, fn -> Zaq.Config.get(:zaq, __MODULE__, [], opts) end)

    cond do
      settings == [] -> {:error, :unconfigured}
      valid_settings?(settings) -> {:ok, settings}
      true -> {:error, :invalid_configuration}
    end
  end

  @doc "Performs one bounded Health call and releases its connection."
  @spec health(keyword()) :: {:ok, :healthy} | {:error, atom()}
  def health(opts \\ []) do
    with {:ok, settings} <- settings(opts) do
      probe(settings, Keyword.get(opts, :connection_name, make_ref()))
    end
  rescue
    _ -> {:error, :invalid_configuration}
  catch
    :exit, _ -> {:error, :unreachable}
  end

  @doc "Releases a probe connection, including after its calling task is cancelled."
  @spec disconnect(reference()) :: :ok
  def disconnect(name) do
    Connection.disconnect(name)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp valid_settings?(settings) do
    Keyword.keyword?(settings) and
      Enum.all?(@required, &(is_binary(settings[&1]) and String.trim(settings[&1]) != "")) and
      Enum.all?(@path_keys, &(Path.type(settings[&1]) == :absolute)) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, settings[:server_name])
  end

  defp probe(settings, name) do
    # A bare socket path takes gRPC's legacy insecure branch even with credentials.
    target = "unix://" <> settings[:socket_path]

    case GRPC.Stub.connect(target,
           name: name,
           adapter: GRPC.Client.Adapters.Gun,
           cred: credential(settings),
           connect_timeout: 1_500,
           adapter_opts: [
             event_handler: {Zaq.Engine.Extension.TLSEvents, nil},
             retry: 0,
             connect_timeout: 1_000,
             tls_handshake_timeout: 1_000,
             await_timeout: 1_200,
             http2_opts: %{closing_timeout: 100}
           ]
         ) do
      {:ok, channel} ->
        try do
          case Gateway.Stub.health(channel, %HealthRequest{}, timeout: 2_000) do
            {:ok, %HealthResponse{status: "ok"}} -> {:ok, :healthy}
            {:ok, %HealthResponse{}} -> {:error, :unexpected_status}
            {:error, _} -> {:error, :rpc_error}
          end
        after
          disconnect(name)
        end

      {:error, reason} ->
        {:error, connection_error(reason)}
    end
  end

  defp credential(settings) do
    GRPC.Credential.new(
      ssl: [
        cacertfile: settings[:ca_cert],
        certfile: settings[:client_cert],
        keyfile: settings[:client_key],
        verify: :verify_peer,
        versions: [:"tlsv1.3"],
        server_name_indication: String.to_charlist(settings[:server_name]),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        alpn_advertised_protocols: ["h2"]
      ]
    )
  end

  defp connection_error({:tls_alert, _}), do: :tls_error
  defp connection_error(:alpn_required), do: :tls_error
  defp connection_error({:options, _}), do: :invalid_configuration

  defp connection_error(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> connection_error()

  defp connection_error(reasons) when is_list(reasons) do
    Enum.find_value(reasons, :unreachable, fn reason ->
      case connection_error(reason) do
        :unreachable -> nil
        error -> error
      end
    end)
  end

  defp connection_error(_reason), do: :unreachable
end
