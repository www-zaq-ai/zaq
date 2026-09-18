defmodule Zaq.Engine.Connect.ResolvedCredential do
  @moduledoc """
  Ephemeral authentication for trusted in-process runtime consumers only.

  This is not an Ecto schema or a transport DTO and intentionally has no JSON
  encoder. Inspection exposes dependency IDs and auth kind only. Callers must not
  serialize, persist, log `authentication`, or put this value into public events.

  API keys are literal `api_key` strings; OAuth supplies only a literal access
  token, never refresh tokens or client secrets. JWT supplies a private PEM key
  and configured signing identity/profile, not a minted assertion. `bearer` means
  a consumer should apply Bearer formatting; `raw` means the literal value. This
  module does not select a transport header, sign JWTs or produce provider options.
  Metadata is limited to selected-grant account ID/name strings. `expires_at` is the
  earliest local configuration or selected-grant deadline; `nil` means neither has one.
  """

  @enforce_keys [
    :credential_id,
    :grant_id,
    :owner_type,
    :owner_id,
    :auth_kind,
    :request_format,
    :authentication
  ]
  @derive {Inspect, only: [:credential_id, :grant_id, :owner_type, :owner_id, :auth_kind]}
  defstruct @enforce_keys ++ [metadata: %{}, expires_at: nil]

  @type authentication ::
          %{api_key: String.t()}
          | %{access_token: String.t()}
          | %{
              private_key: String.t(),
              issuer: String.t(),
              key_id: String.t(),
              subject: String.t() | nil,
              scopes: [String.t()],
              auth_profile_id: String.t()
            }
  @type t :: %__MODULE__{
          credential_id: pos_integer(),
          grant_id: pos_integer(),
          owner_type: String.t(),
          owner_id: pos_integer() | nil,
          auth_kind: String.t(),
          request_format: String.t(),
          authentication: authentication(),
          metadata: %{optional(String.t()) => String.t()},
          expires_at: DateTime.t() | nil
        }
end
