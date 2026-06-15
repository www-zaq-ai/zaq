defmodule Zaq.E2E.PortalStateTest do
  use ExUnit.Case, async: false

  alias Zaq.E2E.PortalState

  setup do
    # PortalState is only supervised when e2e_routes: true (E2E=1 mode).
    # start_supervised/1 gives each test a fresh process and cleans it up
    # automatically — no on_exit needed.
    start_supervised!(PortalState)
    :ok
  end

  describe "default state" do
    test "no email conflicts registered" do
      refute PortalState.conflict_email?("anyone@example.com")
    end
  end

  describe "register_conflict/1" do
    test "email conflict is detected" do
      PortalState.register_conflict(email: "taken@example.com")
      assert PortalState.conflict_email?("taken@example.com")
    end

    test "email conflict does not affect other emails" do
      PortalState.register_conflict(email: "taken@example.com")
      refute PortalState.conflict_email?("safe@example.com")
    end

    test "multiple conflicts accumulate" do
      PortalState.register_conflict(email: "a@a.com")
      PortalState.register_conflict(email: "b@b.com")

      assert PortalState.conflict_email?("a@a.com")
      assert PortalState.conflict_email?("b@b.com")
    end
  end

  describe "reset/0" do
    test "clears all registered email conflicts" do
      PortalState.register_conflict(email: "taken@example.com")
      PortalState.reset()
      refute PortalState.conflict_email?("taken@example.com")
    end

    test "reset is idempotent on an already-empty state" do
      PortalState.reset()
      PortalState.reset()
      refute PortalState.conflict_email?("any@example.com")
    end
  end
end
