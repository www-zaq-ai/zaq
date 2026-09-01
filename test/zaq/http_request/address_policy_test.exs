defmodule Zaq.HttpRequest.AddressPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.HttpRequest.AddressPolicy
  alias Zaq.System.OutboundHttpPolicy

  defp policy(overrides \\ %{}), do: struct!(OutboundHttpPolicy, overrides)

  defp ip!(value) do
    {:ok, ip} = AddressPolicy.parse_ip(value)
    ip
  end

  test "blocks private and special-use addresses by default" do
    cases = [
      {"127.0.0.1", :blocked_loopback},
      {"10.0.0.1", :blocked_private_network},
      {"172.16.0.1", :blocked_private_network},
      {"192.168.1.1", :blocked_private_network},
      {"169.254.1.1", :blocked_link_local},
      {"169.254.169.254", :blocked_link_local},
      {"100.64.0.1", :blocked_carrier_grade_nat},
      {"224.0.0.1", :blocked_multicast},
      {"0.0.0.0", :blocked_unspecified},
      {"192.0.2.1", :blocked_reserved},
      {"::1", :blocked_loopback},
      {"fe80::1", :blocked_link_local},
      {"fc00::1", :blocked_ipv6_unique_local},
      {"ff00::1", :blocked_multicast},
      {"::", :blocked_unspecified}
    ]

    for {address, reason} <- cases do
      assert {:error, ^reason, _} = AddressPolicy.validate(ip!(address), policy())
    end
  end

  test "allows public addresses when no blacklist matches" do
    assert :ok = AddressPolicy.validate(ip!("93.184.216.34"), policy())
  end

  test "enforces exact IP and CIDR blacklists" do
    assert {:error, :ip_blacklisted, _} =
             AddressPolicy.validate(
               ip!("93.184.216.34"),
               policy(%{blacklisted_ips: ["93.184.216.34"]})
             )

    assert {:error, :cidr_blacklisted, _} =
             AddressPolicy.validate(
               ip!("93.184.216.34"),
               policy(%{blacklisted_cidrs: ["93.184.216.0/24"]})
             )
  end

  test "blocks cloud metadata even when link-local addresses are allowed" do
    policy = policy(%{block_link_local: false})

    assert {:error, :blocked_cloud_metadata, _} =
             AddressPolicy.validate(ip!("169.254.169.254"), policy)

    assert :ok = AddressPolicy.validate(ip!("169.254.169.253"), policy)
  end

  test "ignores malformed and nonmatching blacklist entries" do
    assert :ok =
             AddressPolicy.validate(
               ip!("93.184.216.34"),
               policy(%{blacklisted_ips: ["not-an-ip", "93.184.216.35"]})
             )

    assert {:error, :ip_blacklisted, _} =
             AddressPolicy.validate(
               ip!("93.184.216.34"),
               policy(%{blacklisted_ips: ["not-an-ip", "93.184.216.35", "93.184.216.34"]})
             )
  end

  property "blocks every address in the IPv6 blacklist CIDR" do
    check all(
            hextets <- StreamData.list_of(StreamData.integer(0..0xFFFF), length: 6),
            outside_second_hextet <-
              StreamData.filter(StreamData.integer(0..0xFFFF), &(&1 != 0x4700)),
            max_runs: 100
          ) do
      address = Enum.map_join([0x2606, 0x4700 | hextets], ":", &Integer.to_string(&1, 16))

      assert {:error, :cidr_blacklisted, _} =
               AddressPolicy.validate(
                 ip!(address),
                 policy(%{blacklisted_cidrs: ["2606:4700::/32"]})
               )

      outside =
        Enum.map_join(
          [0x2606, outside_second_hextet | hextets],
          ":",
          &Integer.to_string(&1, 16)
        )

      assert :ok =
               AddressPolicy.validate(
                 ip!(outside),
                 policy(%{blacklisted_cidrs: ["2606:4700::/32"]})
               )
    end
  end

  test "blocks reserved IPv4 ranges" do
    for address <- ["198.51.100.1", "203.0.113.1", "240.0.0.1", "255.255.255.255"] do
      assert {:error, :blocked_reserved, _} = AddressPolicy.validate(ip!(address), policy())
    end
  end

  property "blocks all IPv4 addresses with a reserved first octet" do
    check all(
            first_octet <- StreamData.integer(240..255),
            second_octet <- StreamData.integer(0..255),
            third_octet <- StreamData.integer(0..255),
            fourth_octet <- StreamData.integer(0..255),
            max_runs: 100
          ) do
      address = Enum.join([first_octet, second_octet, third_octet, fourth_octet], ".")

      assert {:error, :blocked_reserved, _} = AddressPolicy.validate(ip!(address), policy())
    end
  end
end
