defmodule Zaq.UserPortalTest do
  use ExUnit.Case, async: true

  alias Zaq.UserPortal

  describe "plan_enabled?/1" do
    test "true when plan_status is enabled" do
      assert UserPortal.plan_enabled?(%{"plan_status" => "enabled"})
    end

    test "false for any other status, missing field, or nil" do
      refute UserPortal.plan_enabled?(%{"plan_status" => "disabled"})
      refute UserPortal.plan_enabled?(%{})
      refute UserPortal.plan_enabled?(nil)
    end
  end

  describe "plan_available?/1" do
    test "true only when available is exactly true" do
      assert UserPortal.plan_available?(%{"available" => true})
    end

    test "false for missing/false/non-boolean available and nil metadata" do
      refute UserPortal.plan_available?(%{"available" => false})
      refute UserPortal.plan_available?(%{"available" => "true"})
      refute UserPortal.plan_available?(%{})
      refute UserPortal.plan_available?(nil)
    end
  end

  describe "plan_active?/1" do
    test "true only when both enabled and available" do
      assert UserPortal.plan_active?(%{"plan_status" => "enabled", "available" => true})
    end

    test "false when either condition is missing" do
      refute UserPortal.plan_active?(%{"plan_status" => "enabled"})
      refute UserPortal.plan_active?(%{"available" => true})
      refute UserPortal.plan_active?(nil)
    end
  end

  describe "provision_error/1" do
    test "409 with a message returns the portal message plus override hint" do
      assert {msg, :allow_override} =
               UserPortal.provision_error({409, %{"message" => "Already registered."}})

      assert msg == "Already registered. Please use a different email address."
    end

    test "409 without a usable message falls back to a default conflict message" do
      assert {msg, :allow_override} = UserPortal.provision_error({409, %{}})
      assert msg =~ "already registered with ZAQ Portal"
      assert msg =~ "Please use a different email address."
    end

    test "non-409 status with a message surfaces it without override" do
      assert {"Service is down.", :none} =
               UserPortal.provision_error({503, %{"message" => "Service is down."}})
    end

    test "generic/unknown errors return the fallback message without override" do
      assert {msg, :none} = UserPortal.provision_error(:econnrefused)
      assert msg =~ "Could not reach the ZAQ portal"
    end
  end
end
