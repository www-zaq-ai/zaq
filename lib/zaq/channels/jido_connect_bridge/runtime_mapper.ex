defmodule Zaq.Channels.JidoConnectBridge.RuntimeMapper do
  @moduledoc "Maps persisted Connect credentials/grants into jido_connect runtime contracts."

  alias Jido.Connect.{Connection, CredentialLease}
  alias Zaq.Engine.Connect.{Credential, Grant}

  @spec to_connection(Grant.t()) :: Jido.Connect.Connection.t()
  def to_connection(%Grant{} = grant) do
    Connection.new!(%{
      id: "grant:#{grant.id}",
      provider: String.to_atom(grant.provider),
      profile: profile_from_grant(grant),
      tenant_id: "zaq",
      owner_type: String.to_atom(grant.owner_type),
      owner_id: normalize_owner_id(grant.owner_id),
      subject: %{},
      status: :connected,
      credential_ref: "credential:#{grant.credential_id}",
      scopes: grant.scopes || [],
      metadata: grant.metadata || %{}
    })
  end

  @spec to_credential_lease(Grant.t(), Credential.t()) :: Jido.Connect.CredentialLease.t()
  def to_credential_lease(%Grant{} = grant, %Credential{} = credential) do
    fields =
      case grant.auth_kind do
        "oauth2" ->
          %{
            access_token: grant.access_token,
            refresh_token: grant.refresh_token,
            scopes: grant.scopes || []
          }

        "api_key" ->
          %{
            api_key: grant.api_key || credential.api_key
          }

        # jido_connect ServiceAccount expects client_email/private_key_id keys
        "jwt_bearer" ->
          %{
            access_token: grant.access_token,
            scopes: grant.scopes || [],
            issuer: grant.issuer,
            client_email: grant.issuer,
            private_key: grant.private_key,
            key_id: grant.key_id,
            private_key_id: grant.key_id,
            subject: grant.subject
          }
          |> reject_blank_fields()
      end

    connection = to_connection(grant)

    CredentialLease.from_connection!(
      connection,
      fields,
      expires_at: grant.expires_at || DateTime.add(DateTime.utc_now(), 3600, :second),
      metadata: grant.metadata || %{}
    )
  end

  defp normalize_owner_id(nil), do: "org"
  defp normalize_owner_id(owner_id), do: to_string(owner_id)

  defp profile_from_grant(%Grant{} = grant) do
    metadata = grant.metadata || %{}

    profile =
      Map.get(metadata, "auth_profile_id") ||
        Map.get(metadata, :auth_profile_id) ||
        grant.auth_kind

    String.to_atom(profile)
  end

  defp reject_blank_fields(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
