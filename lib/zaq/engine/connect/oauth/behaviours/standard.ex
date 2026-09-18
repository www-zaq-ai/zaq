defmodule Zaq.Engine.Connect.OAuth.Behaviours.Standard do
  @moduledoc "Standard OAuth2 behavior with no provider-specific customization."

  @behaviour Zaq.Engine.Connect.OAuth.Behaviour

  @impl true
  def redirect_uri(_credential, default_uri), do: default_uri

  @impl true
  def pkce_required?(_credential), do: false

  @impl true
  def authorize_params(_credential), do: %{}

  @impl true
  def normalize_token_payload(payload), do: payload

  @impl true
  def valid_grant_metadata?(metadata), do: metadata == %{}
end
