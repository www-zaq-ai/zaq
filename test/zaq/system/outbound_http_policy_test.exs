defmodule Zaq.System.OutboundHttpPolicyTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.System
  alias Zaq.System.OutboundHttpPolicy

  describe "changeset/2" do
    test "secure defaults keep outbound HTTP disabled and private protections on" do
      policy = %OutboundHttpPolicy{}

      assert policy.enabled == false
      assert policy.block_loopback == true
      assert policy.block_private_networks == true
      assert policy.block_link_local == true
      assert policy.block_cloud_metadata == true
      assert policy.block_carrier_grade_nat == true
      assert policy.block_multicast == true
      assert policy.block_unspecified == true
      assert policy.block_reserved == true
      assert policy.block_ipv6_unique_local == true
      assert policy.allowed_methods == ~w(GET HEAD OPTIONS)
      assert policy.follow_redirects == false
    end

    test "normalizes list values and method casing" do
      changeset =
        OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{
          allowed_methods: ["get", " POST ", "GET"],
          blacklisted_hosts: [" API.Example.COM ", "api.example.com", ""],
          blacklisted_ips: [" 10.0.0.1 "],
          blacklisted_cidrs: [" 10.0.0.0/8 "],
          allowed_ports: [443, 443, 8443]
        })

      assert changeset.valid?
      policy = Ecto.Changeset.apply_changes(changeset)
      assert policy.allowed_methods == ~w(GET POST)
      assert policy.blacklisted_hosts == ["api.example.com"]
      assert policy.blacklisted_ips == ["10.0.0.1"]
      assert policy.blacklisted_cidrs == ["10.0.0.0/8"]
      assert policy.allowed_ports == [443, 8443]
    end

    test "rejects unsupported methods and empty method policy" do
      assert %{allowed_methods: [_ | _]} =
               errors_on(
                 OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{allowed_methods: ["TRACE"]})
               )

      assert %{allowed_methods: [_ | _]} =
               errors_on(
                 OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{allowed_methods: []})
               )
    end

    test "rejects invalid transport limits" do
      changeset =
        OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{
          max_timeout_ms: 0,
          max_response_bytes: 0,
          allowed_ports: [0, 65_536, "443"]
        })

      assert %{max_timeout_ms: [_], max_response_bytes: [_], allowed_ports: [_]} =
               errors_on(changeset)
    end

    test "keeps redirects disabled until safe redirect handling exists" do
      changeset = OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{follow_redirects: true})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).follow_redirects == false
    end
  end

  describe "System outbound HTTP policy" do
    test "loads secure defaults when no persisted settings exist" do
      assert %OutboundHttpPolicy{} = policy = System.get_outbound_http_policy()
      assert policy.enabled == false
      assert policy.allowed_methods == ~w(GET HEAD OPTIONS)
      assert policy.follow_redirects == false
    end

    test "persists and reloads validated settings" do
      changeset =
        OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{
          enabled: true,
          block_private_networks: false,
          allowed_methods: ["GET", "POST"],
          blacklisted_hosts: ["api.internal.test"],
          blacklisted_ips: ["10.0.0.2"],
          blacklisted_cidrs: ["10.0.0.0/8"],
          allowed_ports: [443, 8443],
          max_timeout_ms: 5_000,
          max_response_bytes: 2048
        })

      assert {:ok, saved} = System.save_outbound_http_policy(changeset)
      assert saved.enabled == true
      assert saved.block_private_networks == false
      assert saved.allowed_methods == ~w(GET POST)
      assert saved.blacklisted_hosts == ["api.internal.test"]
      assert saved.blacklisted_ips == ["10.0.0.2"]
      assert saved.blacklisted_cidrs == ["10.0.0.0/8"]
      assert saved.allowed_ports == [443, 8443]
      assert saved.max_timeout_ms == 5_000
      assert saved.max_response_bytes == 2048

      assert System.get_config("outbound_http.enabled") == "true"
      assert System.get_config("outbound_http.allowed_methods") == ~s(["GET","POST"])
    end

    test "returns invalid changesets without persistence" do
      changeset = OutboundHttpPolicy.changeset(%OutboundHttpPolicy{}, %{allowed_methods: []})

      assert {:error, ^changeset} = System.save_outbound_http_policy(changeset)
      assert System.get_config("outbound_http.allowed_methods") == nil
    end

    test "falls back safely for empty and malformed list settings" do
      for {field, value} <- [
            {"blacklisted_hosts", ""},
            {"blacklisted_ips", ""},
            {"blacklisted_cidrs", ""},
            {"allowed_methods", ""},
            {"allowed_ports", ""},
            {"blacklisted_hosts", "not-json"},
            {"blacklisted_hosts", "true"},
            {"blacklisted_hosts", "{}"},
            {"allowed_ports", "not-json"},
            {"allowed_ports", "true"},
            {"allowed_ports", "{}"}
          ] do
        assert {:ok, _} = System.set_config("outbound_http.#{field}", value)
      end

      policy = System.get_outbound_http_policy()
      assert policy.blacklisted_hosts == []
      assert policy.blacklisted_ips == []
      assert policy.blacklisted_cidrs == []
      assert policy.allowed_methods == ~w(GET HEAD OPTIONS)
      assert policy.allowed_ports == []
    end

    test "parses mixed JSON port values and drops invalid values" do
      assert {:ok, _} =
               System.set_config("outbound_http.allowed_ports", ~s(["443","invalid",8443]))

      assert System.get_outbound_http_policy().allowed_ports == [443, 8443]
    end

    property "JSON scalar list settings preserve safe fallbacks" do
      check all(value <- StreamData.member_of(["null", "true", "false", "0", ~s("text")])) do
        assert {:ok, _} = System.set_config("outbound_http.blacklisted_hosts", value)
        assert {:ok, _} = System.set_config("outbound_http.allowed_methods", value)
        assert {:ok, _} = System.set_config("outbound_http.allowed_ports", value)

        policy = System.get_outbound_http_policy()
        assert policy.blacklisted_hosts == []
        assert policy.allowed_methods == ~w(GET HEAD OPTIONS)
        assert policy.allowed_ports == []
      end
    end
  end
end
