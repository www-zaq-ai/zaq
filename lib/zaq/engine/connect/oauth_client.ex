defmodule Zaq.Engine.Connect.OAuthClient do
  @moduledoc "Behaviour for provider-specific OAuth2 code exchange operations."

  @callback exchange_code(provider :: String.t(), params :: map()) ::
              {:ok,
               %{
                 access_token: String.t(),
                 refresh_token: String.t() | nil,
                 scopes: [String.t()],
                 expires_at: DateTime.t() | nil
               }}
              | {:error, term()}
end
