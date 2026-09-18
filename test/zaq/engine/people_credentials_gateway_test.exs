defmodule Zaq.Engine.PeopleCredentialsGatewayTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Engine.{Api, Connect, Events, PeopleAuthGateway}
  alias Zaq.Engine.Connect.{Credential, OAuthAttempt, OAuthAttempts, OAuthState}
  alias Zaq.TestSupport.ConnectOAuthAttemptConfig

  setup do
    Repo.delete_all(PeoplePermissionGrant)

    {:ok, person} =
      People.create_person(%{
        full_name: "Credential self service",
        email: "credential-self-service@example.test"
      })

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 3, 1, 1})

    {:ok, %{token: token, session: session}} =
      PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "self-service-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: "api_key",
        secret_binding: :grant,
        personal_credential_policy: :required
      })

    %{person: person, token: token, session: session, credential: credential}
  end

  test "reads require authentication and writes require manage_credentials", ctx do
    assert {:ok, [summary]} = dispatch(:list_self_credentials, ctx.token)
    assert summary.credential_id == ctx.credential.id

    assert {:error, :forbidden} =
             dispatch(:put_self_credential, ctx.token, %{
               credential_id: ctx.credential.id,
               person_id: -1,
               material: %{api_key: "PERSON_KEY"}
             })

    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    assert {:error, :invalid_material} =
             dispatch(:put_self_credential, ctx.token, %{
               credential_id: ctx.credential.id,
               person_id: -1,
               material: %{api_key: "PERSON_KEY", owner_id: -1}
             })

    assert {:ok, %{credential_id: id, status: "active"}} =
             dispatch(:put_self_credential, ctx.token, %{
               credential_id: ctx.credential.id,
               person_id: -1,
               material: %{api_key: "PERSON_KEY"}
             })

    assert id == ctx.credential.id
    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)

    assert {:error, :forbidden} =
             dispatch(:revoke_self_credential, ctx.token, %{credential_id: id})
  end

  test "revoked sessions and inactive People cannot manage credentials", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, _} = PeopleAuth.revoke_session(ctx.token)

    assert {:error, :invalid_session} =
             dispatch(:put_self_credential, ctx.token, %{
               credential_id: ctx.credential.id,
               material: %{api_key: "DENIED"}
             })

    assert Repo.get!(Credential, ctx.credential.id)
  end

  test "authorized own-slot status, revocation and removal share canonical mutations", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    assert {:ok, %{status: "absent"}} =
             dispatch(:get_self_credential, ctx.token, %{credential_id: ctx.credential.id})

    assert {:ok, %{status: "active"}} =
             dispatch(:put_self_credential, ctx.token, %{
               credential_id: ctx.credential.id,
               material: %{api_key: "PERSON_KEY"}
             })

    assert {:ok, %{status: "revoked"}} =
             dispatch(:revoke_self_credential, ctx.token, %{credential_id: ctx.credential.id})

    assert {:ok, %{status: "revoked"}} =
             dispatch(:get_self_credential, ctx.token, %{credential_id: ctx.credential.id})

    assert {:ok, %{status: "absent"}} =
             dispatch(:remove_self_credential, ctx.token, %{credential_id: ctx.credential.id})

    assert {:error, :invalid_request} =
             PeopleAuthGateway.dispatch(%{op: :put_self_credential, token: ctx.token}, [])
  end

  test "credential operations require the existing confidential Engine boundary", ctx do
    request = %{op: :list_self_credentials, token: ctx.token}
    public = Events.build_invoke_event(request, :people_auth)

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(public, :people_auth, %{})

    confidential =
      Events.build_invoke_event(request, :people_auth, event_opts: [confidential: true])

    assert %{response: {:ok, [_]}} = Api.handle_event(confidential, :people_auth, %{})
  end

  test "OAuth attempts bind to the authenticated session and reject its revocation", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "self-service-oauth-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "client",
        scopes: ["read"],
        metadata: %{
          "authorize_url" => "https://provider.example/authorize",
          "token_url" => "https://provider.example/token",
          "pkce" => true
        }
      })

    request = %{
      op: :start_self_credential_oauth,
      token: ctx.token,
      credential_id: credential.id
    }

    assert {:ok, %{authorize_url: url}} =
             PeopleAuthGateway.dispatch(request, config: ConnectOAuthAttemptConfig)

    state = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("state")
    assert {:ok, %{"attempt_id" => id}} = OAuthState.verify(state)
    assert Repo.get!(OAuthAttempt, id).session_id == ctx.session.id

    {:ok, _} = PeopleAuth.revoke_session(ctx.token)

    assert {:error, :invalid_attempt} =
             OAuthAttempts.finalize_callback(
               "example",
               %{"state" => state, "code" => "unused"},
               config: ConnectOAuthAttemptConfig
             )
  end

  test "OAuth completion rechecks manage_credentials", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "permission-oauth-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "client",
        scopes: ["read"],
        metadata: %{
          "authorize_url" => "https://provider.example/authorize",
          "token_url" => "https://provider.example/token",
          "pkce" => true
        }
      })

    assert {:ok, %{authorize_url: url}} =
             PeopleAuthGateway.dispatch(
               %{
                 op: :start_self_credential_oauth,
                 token: ctx.token,
                 credential_id: credential.id
               },
               config: ConnectOAuthAttemptConfig
             )

    state = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("state")
    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)

    assert {:error, :invalid_attempt} =
             OAuthAttempts.finalize_callback(
               "example",
               %{"state" => state, "code" => "unused"},
               config: ConnectOAuthAttemptConfig
             )
  end

  defp dispatch(op, token, params \\ %{}),
    do: PeopleAuthGateway.dispatch(Map.merge(params, %{op: op, token: token}), [])
end
