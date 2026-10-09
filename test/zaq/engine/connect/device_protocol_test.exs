defmodule Zaq.Engine.Connect.DeviceProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.Credential
  alias Zaq.Engine.Connect.OAuth.Device.Codex

  @credential %Credential{client_id: "codex-client"}

  test "Codex initiation and string interval are normalized without exposing device material" do
    assert %{url: "https://auth.openai.com/api/accounts/deviceauth/usercode", json: body} =
             Codex.initiate_request(@credential)

    assert body == %{client_id: "codex-client"}

    assert {:ok, instructions} =
             Codex.initiate_response(200, %{
               "device_auth_id" => "private-device-id",
               "user_code" => "ABCD-EFGH",
               "interval" => "7"
             })

    assert instructions.interval == 7
    assert instructions.expires_in == 900
    assert instructions.verification_uri == "https://auth.openai.com/codex/device"

    assert instructions.material == %{
             "device_auth_id" => "private-device-id",
             "user_code" => "ABCD-EFGH"
           }
  end

  test "Codex pending statuses and slowdown remain provider decisions" do
    assert {:pending, 7} = Codex.poll_response(403, %{}, 7)
    assert {:pending, 7} = Codex.poll_response(404, %{}, 7)
    assert {:pending, 12} = Codex.poll_response(429, %{"error" => "slow_down"}, 7)
    assert {:terminal, :denied} = Codex.poll_response(400, %{"error" => "access_denied"}, 7)
    assert {:terminal, :expired} = Codex.poll_response(400, %{"error" => "expired_token"}, 7)
    assert {:terminal, :failed} = Codex.poll_response(500, %{}, 7)
  end

  test "approval requires code and verifier and exchanges against the device redirect" do
    response = %{"authorization_code" => "code", "code_verifier" => "verifier"}
    assert {:exchange, ^response} = Codex.poll_response(200, response, 5)

    assert %{url: "https://auth.openai.com/oauth/token", form: form} =
             Codex.exchange_request(@credential, response)

    assert form["redirect_uri"] == "https://auth.openai.com/deviceauth/callback"
    assert form["code_verifier"] == "verifier"
    assert form["grant_type"] == "authorization_code"
    assert {:terminal, :failed} = Codex.poll_response(200, %{"authorization_code" => "code"}, 5)
  end

  property "invalid provider timing never becomes scheduling instructions" do
    check all(interval <- integer(-10_000..0)) do
      assert {:error, :oauth_failed} =
               Codex.initiate_response(200, %{
                 "device_auth_id" => "device",
                 "user_code" => "code",
                 "interval" => interval
               })
    end
  end
end
