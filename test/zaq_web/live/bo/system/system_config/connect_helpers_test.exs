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

  test "sanitize_credential_params/1 returns default scopes for non-map input" do
    assert ConnectHelpers.sanitize_credential_params(nil) == %{"scopes" => []}
    assert ConnectHelpers.sanitize_credential_params("scopes=openid") == %{"scopes" => []}
    assert ConnectHelpers.sanitize_credential_params([:openid]) == %{"scopes" => []}
  end
end
