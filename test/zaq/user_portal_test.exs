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
    test "409 returns the fixed 'set your key on the ZAQ Router' guidance" do
      # The email already exists on the portal, so re-provisioning cannot help —
      # the user must fetch their existing key and set it on the ZAQ Router. The
      # portal's own body is ignored in favour of this actionable message.
      msg = UserPortal.provision_error({409, %{"message" => "Already registered."}})

      assert msg =~ "already registered in the user portal"
      assert msg =~ "ZAQ Router"
    end

    test "409 with no body returns the same fixed guidance" do
      msg = UserPortal.provision_error({409, %{}})
      assert msg =~ "already registered in the user portal"
      assert msg =~ "ZAQ Router"
    end

    test "non-409 status with a message surfaces it" do
      assert "Service is down." =
               UserPortal.provision_error({503, %{"message" => "Service is down."}})
    end

    test "generic/unknown errors return the fallback message" do
      msg = UserPortal.provision_error(:econnrefused)
      assert msg =~ "Could not reach the ZAQ portal"
    end
  end
end
