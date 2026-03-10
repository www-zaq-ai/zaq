defmodule ZaqWeb.Components.ServiceUnavailableTest do
  use ExUnit.Case, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.ServiceUnavailable

  setup :verify_on_exit!

  # In test env, NodeRouter is replaced by Zaq.NodeRouterMock
  # configured in config/test.exs:
  #   config :zaq, :node_router, Zaq.NodeRouterMock

  describe "available?/1" do
    test "returns true when all roles are running on local node" do
      Zaq.NodeRouterMock
      |> expect(:find_node, fn _supervisor -> node() end)
      |> expect(:find_node, fn _supervisor -> node() end)

      # bo and agent supervisors are running locally in test env
      assert ServiceUnavailable.available?([:bo, :agent]) == true
    end

    test "returns true when role is running on a peer node" do
      peer = :ai@localhost

      expect(Zaq.NodeRouterMock, :find_node, fn _supervisor -> peer end)

      # find_node returns a peer — role_running? returns true without
      # checking Process.whereis locally
      assert ServiceUnavailable.available?([:agent]) == true
    end

    test "returns false when role is not running anywhere" do
      expect(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)

      assert ServiceUnavailable.available?([:channels]) == false
    end

    test "returns false when any one role in a list is not running" do
      Zaq.NodeRouterMock
      |> expect(:find_node, fn _supervisor -> node() end)
      |> expect(:find_node, fn _supervisor -> nil end)

      assert ServiceUnavailable.available?([:bo, :channels]) == false
    end

    test "returns true for empty list" do
      assert ServiceUnavailable.available?([]) == true
    end
  end

  describe "missing_roles/1" do
    test "returns empty list when all roles are running" do
      expect(Zaq.NodeRouterMock, :find_node, fn _supervisor -> node() end)

      assert ServiceUnavailable.missing_roles([:bo]) == []
    end

    test "returns missing roles when supervisor not running locally and no peer" do
      expect(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)

      missing = ServiceUnavailable.missing_roles([:channels])
      assert missing == [:channels]
    end

    test "returns only missing roles from a mixed list" do
      Zaq.NodeRouterMock
      |> expect(:find_node, fn _supervisor -> node() end)
      |> expect(:find_node, fn _supervisor -> nil end)

      missing = ServiceUnavailable.missing_roles([:bo, :channels])
      assert missing == [:channels]
    end

    test "returns empty list for empty input" do
      assert ServiceUnavailable.missing_roles([]) == []
    end
  end

  describe "page/1" do
    test "renders singular copy and role hint for one missing service" do
      expect(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)

      html =
        render_component(&ServiceUnavailable.page/1,
          current_user: %{username: "alice", role: %{name: "admin"}},
          current_path: "/bo/ai-diagnostics",
          page_title: "Diagnostics",
          services: [:agent]
        )

      assert html =~ "Service Unavailable"
      assert html =~ "following service"
      assert html =~ "required role"
      assert html =~ "Agent"
      assert html =~ "ROLES=agent"
      assert html =~ "Connected nodes"
      assert html =~ "none"
    end

    test "renders plural copy and multi-role hint for many missing services" do
      Zaq.NodeRouterMock
      |> expect(:find_node, fn _supervisor -> nil end)
      |> expect(:find_node, fn _supervisor -> nil end)

      html =
        render_component(&ServiceUnavailable.page/1,
          current_user: %{username: "bob", role: %{name: "operator"}},
          current_path: "/bo/channels",
          page_title: "Channels",
          services: [:agent, :channels]
        )

      assert html =~ "following services"
      assert html =~ "required roles"
      assert html =~ "Agent"
      assert html =~ "Channels"
      assert html =~ "ROLES=agent,channels"
    end
  end
end
