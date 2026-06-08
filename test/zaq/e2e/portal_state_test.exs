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

    test "no fingerprint conflicts registered" do
      refute PortalState.conflict_fingerprint?("any-fingerprint")
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

    test "fingerprint conflict is detected" do
      PortalState.register_conflict(fingerprint: "bad-fp-abc")
      assert PortalState.conflict_fingerprint?("bad-fp-abc")
    end

    test "fingerprint conflict does not affect other fingerprints" do
      PortalState.register_conflict(fingerprint: "bad-fp-abc")
      refute PortalState.conflict_fingerprint?("other-fp-xyz")
    end

    test "multiple conflicts accumulate" do
      PortalState.register_conflict(email: "a@a.com")
      PortalState.register_conflict(email: "b@b.com")
      PortalState.register_conflict(fingerprint: "fp1")

      assert PortalState.conflict_email?("a@a.com")
      assert PortalState.conflict_email?("b@b.com")
      assert PortalState.conflict_fingerprint?("fp1")
    end

    test "email and fingerprint can be registered in one call" do
      PortalState.register_conflict(email: "x@x.com", fingerprint: "fp-x")

      assert PortalState.conflict_email?("x@x.com")
      assert PortalState.conflict_fingerprint?("fp-x")
    end
  end

  describe "reset/0" do
    test "clears all registered email conflicts" do
      PortalState.register_conflict(email: "taken@example.com")
      PortalState.reset()
      refute PortalState.conflict_email?("taken@example.com")
    end

    test "clears all registered fingerprint conflicts" do
      PortalState.register_conflict(fingerprint: "bad-fp")
      PortalState.reset()
      refute PortalState.conflict_fingerprint?("bad-fp")
    end

    test "reset is idempotent on an already-empty state" do
      PortalState.reset()
      PortalState.reset()
      refute PortalState.conflict_email?("any@example.com")
    end
  end
end
