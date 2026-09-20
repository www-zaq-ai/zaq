defmodule Zaq.Engine.Connect.OAuth.Behaviour do
  @moduledoc """
  Provider-specific customization points inside Connect's generic OAuth2 lifecycle.

  Implementations may supply protocol parameters and normalize non-secret account
  metadata. They never own state, Actor authorization, HTTP execution, grant writes,
  encryption, or lifecycle notification.
  """

  alias Zaq.Engine.Connect.Credential

  @callback redirect_uri(Credential.t(), default_uri :: String.t()) :: String.t()
  @callback pkce_required?(Credential.t()) :: boolean()
  @callback authorize_params(Credential.t()) :: map()
  @callback normalize_token_payload(map()) :: map()
  @callback valid_grant_metadata?(map()) :: boolean()
  @callback runtime_identity(map()) :: map()
end
