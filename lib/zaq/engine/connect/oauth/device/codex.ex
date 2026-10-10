defmodule Zaq.Engine.Connect.OAuth.Device.Codex do
  @moduledoc """
  Codex device protocol, distinct from the RFC 8628 token polling grant.
  A successful device poll supplies an authorization code and verifier for a final
  code exchange. Codex treats HTTP 403/404 as pending and uses a 15-minute deadline.
  """
  @behaviour Zaq.Engine.Connect.OAuth.Device.Behaviour
  @issuer "https://auth.openai.com"

  @impl true
  def initiate_request(credential),
    do: %{
      url: @issuer <> "/api/accounts/deviceauth/usercode",
      json: %{client_id: credential.client_id}
    }

  @impl true
  def initiate_response(status, body) when status in 200..299 and is_map(body) do
    interval = seconds(Map.get(body, "interval", 5))
    code = body["user_code"] || body["usercode"]

    if nonblank?(body["device_auth_id"]) and nonblank?(code) and interval in 1..900 do
      {:ok,
       %{
         verification_uri: @issuer <> "/codex/device",
         user_code: code,
         interval: interval,
         expires_in: 900,
         material: %{"device_auth_id" => body["device_auth_id"], "user_code" => code}
       }}
    else
      {:error, :oauth_failed}
    end
  end

  def initiate_response(_, _), do: {:error, :oauth_failed}

  @impl true
  def poll_request(_credential, material),
    do: %{
      url: @issuer <> "/api/accounts/deviceauth/token",
      json: Map.take(material, ["device_auth_id", "user_code"])
    }

  @impl true
  def poll_response(status, body, interval) when is_map(body) do
    case body["error"] do
      "slow_down" -> {:pending, interval + 5}
      "authorization_pending" -> {:pending, interval}
      "access_denied" -> {:terminal, :denied}
      "expired_token" -> {:terminal, :expired}
      _ -> poll_status(status, body, interval)
    end
  end

  def poll_response(status, _, interval) when status in [403, 404], do: {:pending, interval}
  def poll_response(_, _, _), do: {:terminal, :failed}

  defp poll_status(status, body, _interval) when status in 200..299 do
    if nonblank?(body["authorization_code"]) and nonblank?(body["code_verifier"]),
      do: {:exchange, Map.take(body, ["authorization_code", "code_verifier"])},
      else: {:terminal, :failed}
  end

  defp poll_status(status, _, interval) when status in [403, 404], do: {:pending, interval}
  defp poll_status(_, _, _), do: {:terminal, :failed}

  @impl true
  def exchange_request(credential, approval) do
    %{
      url: @issuer <> "/oauth/token",
      form: %{
        "client_id" => credential.client_id,
        "code" => approval["authorization_code"],
        "code_verifier" => approval["code_verifier"],
        "grant_type" => "authorization_code",
        "redirect_uri" => @issuer <> "/deviceauth/callback"
      }
    }
  end

  defp nonblank?(value), do: is_binary(value) and byte_size(value) in 1..4096
  defp seconds(value) when is_integer(value), do: value

  defp seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _ -> 0
    end
  end

  defp seconds(_), do: 0
end
