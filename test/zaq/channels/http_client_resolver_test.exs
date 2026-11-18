defmodule Zaq.Channels.HttpClient.ResolverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.HttpClient.Resolver
  alias Zaq.System.OutboundHttpPolicy

  test "literal addresses bypass DNS and preserve policy errors" do
    assert {:ok, [{8, 8, 8, 8}]} = Resolver.resolve("8.8.8.8", %OutboundHttpPolicy{})
    assert {:error, :blocked_loopback, _} = Resolver.resolve("127.0.0.1", %OutboundHttpPolicy{})
    assert {:error, :blocked_loopback, _} = Resolver.resolve("::1", %OutboundHttpPolicy{})
  end

  test "both address families are checked and any blocked answer rejects the host" do
    lookup = fn
      _, :inet -> {:ok, [{8, 8, 8, 8}]}
      _, :inet6 -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
    end

    assert {:error, :blocked_loopback, _} =
             Resolver.resolve("example.test", %OutboundHttpPolicy{}, lookup: lookup)
  end

  test "an absent family is allowed, unexpected partial lookup errors fail closed" do
    for absent <- [{:ok, []}, {:error, :nxdomain}] do
      lookup = fn _, family ->
        if family == :inet, do: absent, else: {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}]}
      end

      assert {:ok, [_]} = Resolver.resolve("example.test", %OutboundHttpPolicy{}, lookup: lookup)
    end

    lookup = fn _, family ->
      if family == :inet, do: {:ok, [{8, 8, 8, 8}]}, else: {:error, :timeout}
    end

    assert {:error, :dns_failed, _} =
             Resolver.resolve("example.test", %OutboundHttpPolicy{}, lookup: lookup)

    assert {:error, :dns_failed, _} =
             Resolver.resolve("example.test", %OutboundHttpPolicy{},
               lookup: fn _, _ -> {:ok, []} end
             )
  end

  test "resolution has a finite shared budget" do
    lookup = fn _, _ ->
      receive do
        :finish -> {:ok, []}
      end
    end

    assert {:error, :dns_failed, _} =
             Resolver.resolve("example.test", %OutboundHttpPolicy{}, lookup: lookup, timeout: 10)
  end

  test "IPv4-mapped loopback and private addresses retain IPv4 restrictions" do
    assert {:error, :blocked_loopback, _} =
             Resolver.resolve("::ffff:127.0.0.1", %OutboundHttpPolicy{})

    assert {:error, :blocked_private_network, _} =
             Resolver.resolve("::ffff:10.0.0.1", %OutboundHttpPolicy{})
  end

  property "candidate order and duplicates cannot bypass a blocked answer" do
    check all(
            addresses <-
              list_of(member_of([{8, 8, 8, 8}, {1, 1, 1, 1}, {127, 0, 0, 1}]),
                min_length: 1,
                max_length: 20
              )
          ) do
      lookup = fn _, family -> if family == :inet, do: {:ok, addresses}, else: {:ok, []} end
      result = Resolver.resolve("example.test", %OutboundHttpPolicy{}, lookup: lookup)

      if {127, 0, 0, 1} in addresses do
        assert {:error, :blocked_loopback, _} = result
      else
        assert {:ok, Enum.uniq(addresses)} == result
      end
    end
  end
end
