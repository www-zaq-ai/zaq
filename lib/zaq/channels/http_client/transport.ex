defmodule Zaq.Channels.HttpClient.Transport do
  @moduledoc """
  Pins Req's network transport to explicit approved peers while retaining its steps.

  Request encoding and credential/signing steps see the logical URL. Only the
  network invocation uses a numeric target. The original authority and TLS hostname
  remain explicit; response processing sees the logical URL again. Each attempt
  uses an isolated, bounded, request-scoped worker. Fallback is restricted to refused
  or unreachable connections, never failures that could follow an HTTP send.
  """

  alias Zaq.Channels.HttpClient.{Connection, Pool, Supervisor}

  @connection_failures [:econnrefused, :enetunreach, :ehostunreach]

  @doc "Executes both response formats through Req's existing response pipeline."
  @spec request(keyword(), [:inet.ip_address()], keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(options, addresses, opts \\ []) do
    deadline =
      Keyword.get_lazy(opts, :deadline, fn ->
        System.monotonic_time(:millisecond) + Keyword.fetch!(options, :receive_timeout)
      end)

    case Supervisor.ensure_started() do
      :ok ->
        options
        |> Req.new()
        |> Req.Request.put_private(:zaq_outbound_transport, {addresses, deadline})
        |> Map.put(:adapter, __MODULE__)
        |> Req.request()

      {:error, _reason} ->
        {:error, %Req.TransportError{reason: :closed}}
    end
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    {addresses, deadline} = request.private.zaq_outbound_transport
    connect(request, addresses, deadline)
  end

  defp connect(request, [address | remaining], deadline) do
    budget = deadline - System.monotonic_time(:millisecond)

    if budget <= 0 do
      {request, %Req.TransportError{reason: :timeout}}
    else
      result =
        Pool.with_pool(
          URI.to_string(request.url),
          [deadline: deadline],
          fn lease ->
            flags = Keyword.fetch!(lease, :send_started)
            response = Connection.request(request, address, deadline, flags)
            {response, :atomics.get(flags, 1) == 1}
          end
        )

      case result do
        {%Req.TransportError{reason: reason}, false}
        when reason in @connection_failures and remaining != [] ->
          connect(request, remaining, deadline)

        {:error, exception} ->
          {request, exception}

        {response, _send_started?} ->
          {request, response}
      end
    end
  end
end
