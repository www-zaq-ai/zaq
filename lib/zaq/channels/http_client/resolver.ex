defmodule Zaq.Channels.HttpClient.Resolver do
  @moduledoc """
  Resolves and validates the complete outbound destination snapshot on Channels.

  Both address families must finish within one budget. An absent family is allowed;
  other lookup failures and any policy-denied address reject the whole destination.
  The trusted runtime boundary can supply an external DNS lookup function through
  `:lookup`; request parameters cannot select it.
  """

  alias Zaq.HttpRequest.AddressPolicy
  alias Zaq.System.OutboundHttpPolicy

  @doc "Returns explicit approved peers, without resolving literal addresses."
  @spec resolve(String.t(), OutboundHttpPolicy.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, atom(), String.t()}
  def resolve(host, policy, opts \\ []) do
    case AddressPolicy.parse_ip(host) do
      {:ok, ip} -> validate([ip], policy)
      {:error, :invalid_ip} -> resolve_hostname(host, policy, opts)
    end
  end

  defp resolve_hostname(host, policy, opts) do
    lookup = Keyword.get(opts, :lookup, &:inet.getaddrs/2)
    task = Task.async(fn -> Enum.map([:inet, :inet6], &lookup.(String.to_charlist(host), &1)) end)

    case Task.yield(task, Keyword.get(opts, :timeout, 5_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, results} -> collect(results, policy)
      _ -> dns_error()
    end
  end

  defp collect(results, policy) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, addresses}, {:ok, collected} -> {:cont, {:ok, collected ++ addresses}}
      {:error, :nxdomain}, acc -> {:cont, acc}
      _, _ -> {:halt, dns_error()}
    end)
    |> case do
      {:ok, []} -> dns_error()
      {:ok, addresses} -> validate(Enum.uniq(addresses), policy)
      error -> error
    end
  end

  defp validate(addresses, policy) do
    Enum.reduce_while(addresses, {:ok, addresses}, fn address, approved ->
      case AddressPolicy.validate(address, policy) do
        :ok -> {:cont, approved}
        error -> {:halt, error}
      end
    end)
  end

  defp dns_error, do: {:error, :dns_failed, "could not resolve approved host addresses"}
end
