defmodule Zaq.HttpRequest.AddressPolicy do
  @moduledoc """
  IP and CIDR policy checks for outbound HTTP destinations.
  """

  alias Zaq.System.OutboundHttpPolicy

  import Bitwise

  @type ip :: :inet.ip_address()

  @doc "Parses an IP address string."
  @spec parse_ip(String.t()) :: {:ok, ip()} | {:error, :invalid_ip}
  def parse_ip(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, :einval} -> {:error, :invalid_ip}
    end
  end

  @doc "Returns `:ok` when `ip` is allowed by policy."
  @spec validate(ip(), OutboundHttpPolicy.t()) :: :ok | {:error, atom(), String.t()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(ip, %OutboundHttpPolicy{} = policy) do
    cond do
      blocked_literal?(ip, policy.blacklisted_ips) ->
        {:error, :ip_blacklisted, "IP address is blacklisted"}

      blocked_cidr?(ip, policy.blacklisted_cidrs) ->
        {:error, :cidr_blacklisted, "IP address is in a blacklisted CIDR"}

      policy.block_loopback and loopback?(ip) ->
        {:error, :blocked_loopback, "loopback destinations are blocked"}

      policy.block_private_networks and private?(ip) ->
        {:error, :blocked_private_network, "private network destinations are blocked"}

      policy.block_link_local and link_local?(ip) ->
        {:error, :blocked_link_local, "link-local destinations are blocked"}

      policy.block_cloud_metadata and cloud_metadata?(ip) ->
        {:error, :blocked_cloud_metadata, "cloud metadata destinations are blocked"}

      policy.block_carrier_grade_nat and carrier_grade_nat?(ip) ->
        {:error, :blocked_carrier_grade_nat, "carrier-grade NAT destinations are blocked"}

      policy.block_multicast and multicast?(ip) ->
        {:error, :blocked_multicast, "multicast destinations are blocked"}

      policy.block_unspecified and unspecified?(ip) ->
        {:error, :blocked_unspecified, "unspecified destinations are blocked"}

      policy.block_reserved and reserved?(ip) ->
        {:error, :blocked_reserved, "reserved destinations are blocked"}

      policy.block_ipv6_unique_local and ipv6_unique_local?(ip) ->
        {:error, :blocked_ipv6_unique_local, "IPv6 unique-local destinations are blocked"}

      true ->
        :ok
    end
  end

  defp blocked_literal?(ip, values) do
    Enum.any?(values, fn value ->
      case parse_ip(value) do
        {:ok, ^ip} -> true
        _ -> false
      end
    end)
  end

  defp blocked_cidr?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  defp in_cidr?(ip, cidr) do
    with [base, bits] <- String.split(cidr, "/", parts: 2),
         {prefix, ""} <- Integer.parse(bits),
         {:ok, base_ip} <- parse_ip(base),
         true <- tuple_size(ip) == tuple_size(base_ip),
         bits when prefix >= 0 and prefix <= bits <- address_bit_size(ip) do
      ip_to_integer(ip) >>> (bits - prefix) == ip_to_integer(base_ip) >>> (bits - prefix)
    else
      _ -> false
    end
  end

  defp address_bit_size({_, _, _, _}), do: 32
  defp address_bit_size({_, _, _, _, _, _, _, _}), do: 128

  defp ip_to_integer({_, _, _, _} = ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< 8) + &1))

  defp ip_to_integer(ip), do: ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< 16) + &1))

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?(_), do: false

  defp link_local?({169, 254, _, _}), do: true
  defp link_local?({0xFE80, b, _, _, _, _, _, _}) when b in 0..0x03FF, do: true
  defp link_local?(_), do: false

  defp cloud_metadata?({169, 254, 169, 254}), do: true
  defp cloud_metadata?(_), do: false

  defp carrier_grade_nat?({100, b, _, _}) when b in 64..127, do: true
  defp carrier_grade_nat?(_), do: false

  defp multicast?({a, _, _, _}) when a in 224..239, do: true
  defp multicast?({a, _, _, _, _, _, _, _}) when (a &&& 0xFF00) == 0xFF00, do: true
  defp multicast?(_), do: false

  defp unspecified?({0, 0, 0, 0}), do: true
  defp unspecified?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp unspecified?(_), do: false

  defp reserved?({192, 0, 2, _}), do: true
  defp reserved?({198, 51, 100, _}), do: true
  defp reserved?({203, 0, 113, _}), do: true
  defp reserved?({a, _, _, _}) when a >= 240, do: true
  defp reserved?(_), do: false

  defp ipv6_unique_local?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp ipv6_unique_local?(_), do: false
end
