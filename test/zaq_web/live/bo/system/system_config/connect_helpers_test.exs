defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.ConnectHelpers

  test "parse_scope_list/1 normalizes comma/newline separated text" do
    input = "openid, profile\nemail, profile"

    assert ConnectHelpers.parse_scope_list(input) == ["openid", "profile", "email"]
  end

  test "parse_scope_list/1 normalizes mixed list inputs" do
    assert ConnectHelpers.parse_scope_list(["openid", " profile ", :email, ""]) == [
             "openid",
             "profile",
             "email"
           ]
  end

  test "sanitize_credential_params/1 drops non-editable keys and parses scopes" do
    params = %{
      "provider" => "google",
      "request_format" => "json",
      "name" => "My Credential",
      "scopes" => "openid, email"
    }

    sanitized = ConnectHelpers.sanitize_credential_params(params)

    refute Map.has_key?(sanitized, "provider")
    refute Map.has_key?(sanitized, "request_format")
    assert sanitized["name"] == "My Credential"
    assert sanitized["scopes"] == ["openid", "email"]
  end

  test "sanitize_credential_params/1 normalizes metadata auth profile and subject" do
    params = %{
      "name" => "JWT Credential",
      "metadata" => %{
        "auth_profile_id" => "domain_delegated_service_account",
        "subject" => "  user@example.com  "
      }
    }

    sanitized = ConnectHelpers.sanitize_credential_params(params)

    assert sanitized["metadata"] == %{
             "auth_profile_id" => "domain_delegated_service_account",
             "subject" => "user@example.com"
           }
  end

  test "sanitize_credential_params/1 sets metadata to empty map when metadata is not a map" do
    params = %{"name" => "JWT Credential", "metadata" => "not-a-map", "scopes" => "openid"}

    sanitized = ConnectHelpers.sanitize_credential_params(params)

    assert sanitized["metadata"] == %{}
    assert sanitized["name"] == "JWT Credential"
    assert sanitized["scopes"] == ["openid"]
  end

  test "sanitize_credential_params/1 drops subject when subject is non-binary" do
    params = %{
      "metadata" => %{
        "auth_profile_id" => "domain_delegated_service_account",
        "subject" => 12_345
      }
    }

    sanitized = ConnectHelpers.sanitize_credential_params(params)

    assert sanitized["metadata"] == %{"auth_profile_id" => "domain_delegated_service_account"}
    refute Map.has_key?(sanitized["metadata"], "subject")
  end

  test "sanitize_credential_params/1 drops subject when subject is blank string" do
    params = %{"metadata" => %{"subject" => "   "}}

    sanitized = ConnectHelpers.sanitize_credential_params(params)

    assert sanitized["metadata"] == %{}
    refute Map.has_key?(sanitized["metadata"], "subject")
  end

  test "sanitize_credential_params/1 returns default scopes for non-map input" do
    assert ConnectHelpers.sanitize_credential_params(nil) == %{"scopes" => []}
    assert ConnectHelpers.sanitize_credential_params("scopes=openid") == %{"scopes" => []}
    assert ConnectHelpers.sanitize_credential_params([:openid]) == %{"scopes" => []}
  end
end
