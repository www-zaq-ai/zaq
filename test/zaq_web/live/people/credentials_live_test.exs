defmodule ZaqWeb.Live.People.CredentialsLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.System

  setup %{conn: conn} do
    Repo.delete_all(PeoplePermissionGrant)

    {:ok, person} =
      People.create_person(%{
        full_name: "Credential Person",
        email: "credential-ui@example.test"
      })

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 8, 1, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

    {:ok, api_ai} =
      System.create_ai_provider_credential(%{
        name: "Personal OpenAI",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        personal_credential_policy: "required"
      })

    {:ok, disabled_ai} =
      System.create_ai_provider_credential(%{
        name: "Company OpenAI",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "GLOBAL_SECRET",
        personal_credential_policy: "disabled"
      })

    %{
      conn: init_test_session(conn, %{person_session_token: token}),
      person: person,
      token: token,
      credential: Connect.get_credential!(api_ai.connect_credential_id),
      disabled: Connect.get_credential!(disabled_ai.connect_credential_id)
    }
  end

  test "lists eligible AI credentials without secrets and hides mutation controls without permission",
       ctx do
    {:ok, view, html} = live(ctx.conn, "/people/credentials")

    assert html =~ "Personal OpenAI"
    assert html =~ "Required"
    assert html =~ "Not configured"
    refute html =~ "Company OpenAI"
    refute html =~ "GLOBAL_SECRET"
    refute has_element?(view, "#credential-form-#{ctx.credential.id}")

    assert has_element?(
             view,
             "#people-settings-menu a[href='/people/credentials']",
             "Credentials"
           )
  end

  test "adds, replaces, revokes and removes a write-only API key", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _html} = live(ctx.conn, "/people/credentials")
    selector = "#credential-form-#{ctx.credential.id}"

    assert view
           |> form(selector, credential: %{api_key: "PERSON_SECRET"})
           |> render_submit() =~ "Credential saved"

    refute render(view) =~ "PERSON_SECRET"
    assert has_element?(view, "#credential-status-#{ctx.credential.id}", "Configured")

    assert view
           |> form(selector, credential: %{api_key: "REPLACEMENT_SECRET"})
           |> render_submit() =~ "Credential saved"

    refute render(view) =~ "REPLACEMENT_SECRET"

    assert view
           |> element("#credential-revoke-#{ctx.credential.id}")
           |> render_click() =~ "Credential revoked"

    assert has_element?(view, "#credential-status-#{ctx.credential.id}", "Revoked")

    assert view
           |> element("#credential-remove-#{ctx.credential.id}")
           |> render_click() =~ "Credential removed"

    assert has_element?(view, "#credential-status-#{ctx.credential.id}", "Not configured")
  end

  test "permission revocation is authoritative on the next mutation", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)

    assert view
           |> form("#credential-form-#{ctx.credential.id}", credential: %{api_key: "DENIED"})
           |> render_submit() =~ "permission"

    refute render(view) =~ "DENIED"
    refute has_element?(view, "#credential-form-#{ctx.credential.id}")
  end

  test "retained grants remain cleanup-only after personal credentials are disabled", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "RETAINED_SECRET"
      })

    {:ok, _} =
      Connect.update_credential(ctx.credential, %{personal_credential_policy: :disabled})

    {:ok, view, html} = live(ctx.conn, "/people/credentials")
    assert html =~ "Personal use is disabled"
    refute html =~ "RETAINED_SECRET"
    refute has_element?(view, "#credential-form-#{ctx.credential.id}")
    assert has_element?(view, "#credential-remove-#{ctx.credential.id}")
  end

  test "starts OAuth for the authenticated Person and refreshes only authoritative status", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, oauth_ai} =
      System.create_ai_provider_credential(%{
        name: "Personal Codex",
        provider: "openai_codex",
        endpoint: "https://chatgpt.com/backend-api",
        personal_credential_policy: "required",
        metadata: %{
          "auth_kind" => "oauth2",
          "auth_profile" => "openai_chatgpt_codex",
          "authorize_url" => "https://auth.openai.com/oauth/authorize",
          "token_url" => "https://auth.openai.com/oauth/token",
          "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
          "scope" => "openid profile email offline_access"
        }
      })

    oauth_id = oauth_ai.connect_credential_id
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    view |> element("#credential-oauth-#{oauth_id}") |> render_click()
    assert_push_event(view, "open_oauth_popup", %{url: url})
    assert url =~ "https://auth.openai.com/oauth/authorize"

    html =
      render_hook(view, "oauth_popup_result", %{"status" => "success", "secret" => "IGNORED"})

    assert html =~ "Connection status refreshed"
    refute html =~ "IGNORED"
    assert has_element?(view, "#credential-status-#{oauth_id}", "Not configured")
  end
end
