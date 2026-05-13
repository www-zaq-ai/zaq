defmodule Zaq.Engine.Connect.OAuthState do
  @moduledoc "Signed OAuth2 state payload helper."

  @salt "zaq.connect.oauth2.state"
  @max_age_seconds 600

  @spec sign(map()) :: String.t()
  def sign(payload) when is_map(payload) do
    Phoenix.Token.sign(ZaqWeb.Endpoint, @salt, payload)
  end

  @spec verify(String.t()) :: {:ok, map()} | {:error, term()}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(ZaqWeb.Endpoint, @salt, token, max_age: @max_age_seconds)
  end
end
