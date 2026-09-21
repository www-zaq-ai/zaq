defmodule ZaqWeb.Live.People.CredentialsLiveTest do
  use ZaqWeb.ConnCase, async: false
  use ExUnitProperties

  require Ecto.Query
  import Phoenix.LiveViewTest

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, OAuthAttempt}
  alias Zaq.Repo
  alias Zaq.System
  alias ZaqWeb.Live.People.CredentialsLive

  setup %{conn: conn} do
    Repo.delete_all(PeoplePermissionGrant)

    {:ok, person} =
      People.create_person(%{
        full_name: "Credential Person",
        email: "credential-ui@example.test"
      })

    sequence = Elixir.System.unique_integer([:positive, :monotonic])

    challenge_ip =
      {127, rem(sequence, 254) + 1, rem(div(sequence, 254), 254) + 1,
       rem(div(sequence, 254 * 254), 254) + 1}

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, challenge_ip)
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

    {:ok, optional_ai} =
      System.create_ai_provider_credential(%{
        name: "Optional OpenAI",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "OPTIONAL_GLOBAL_SECRET",
        personal_credential_policy: "optional"
      })

    %{
      conn: init_test_session(conn, %{person_session_token: token}),
      person: person,
      token: token,
      challenge_ip: challenge_ip,
      credential: Connect.get_credential!(api_ai.connect_credential_id),
      optional: Connect.get_credential!(optional_ai.connect_credential_id),
      disabled: Connect.get_credential!(disabled_ai.connect_credential_id)
    }
  end

  test "lists eligible AI credentials without secrets and hides mutation controls without permission",
       ctx do
    {:ok, view, html} = live(ctx.conn, "/people/credentials")

    assert html =~ "Personal OpenAI"
    assert html =~ "Required"
    assert html =~ "Optional"
    assert html =~ "Not configured"
    refute html =~ "Company OpenAI"
    refute html =~ "GLOBAL_SECRET"
    refute html =~ "OPTIONAL_GLOBAL_SECRET"
    assert has_element?(view, "#people-credentials-table", "Credential type")
    refute has_element?(view, "#credential-form-#{ctx.credential.id}")
    refute has_element?(view, "#credential-edit-#{ctx.credential.id}")

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

    assert has_element?(
             view,
             "#credential-edit-#{ctx.credential.id}.zaq-btn-secondary",
             "Add"
           )

    assert has_element?(
             view,
             "#credential-status-#{ctx.credential.id}.zaq-pill--danger",
             "Not configured"
           )

    assert has_element?(view, ".zaq-pill--danger", "Required")

    assert has_element?(
             view,
             "#credential-status-#{ctx.optional.id}.zaq-pill--elevated",
             "Not configured"
           )

    html = view |> element("#credential-edit-#{ctx.credential.id}") |> render_click()
    assert html =~ "Add AI: Personal OpenAI"
    view |> element("#credential-form-dialog button[aria-label='Close dialog']") |> render_click()
    refute has_element?(view, "#credential-form-dialog")
    view |> element("#credential-edit-#{ctx.credential.id}") |> render_click()

    assert view
           |> form(selector, credential: %{api_key: "PERSON_SECRET"})
           |> render_submit() =~ "Credential saved"

    refute render(view) =~ "PERSON_SECRET"
    assert has_element?(view, "#flash-info.zaq-feedback-banner.zaq-success", "Credential saved")

    assert has_element?(
             view,
             "#credential-status-#{ctx.credential.id}.zaq-pill--success[aria-label='Configured']",
             "Configured"
           )

    view |> element("#credential-edit-#{ctx.credential.id}") |> render_click()
    assert has_element?(view, "#credential-form-dialog", "Edit AI: Personal OpenAI")

    assert view
           |> form(selector, credential: %{api_key: "REPLACEMENT_SECRET"})
           |> render_submit() =~ "Credential saved"

    refute render(view) =~ "REPLACEMENT_SECRET"

    assert view
           |> element("#credential-revoke-#{ctx.credential.id}")
           |> render_click() =~ "Revoke credential?"

    assert view
           |> element("#credential-revoke-dialog button[phx-click=confirm_credential_action]")
           |> render_click() =~ "Credential revoked"

    assert has_element?(view, "#credential-status-#{ctx.credential.id}[aria-label='Revoked']")

    assert view
           |> element("#credential-remove-#{ctx.credential.id}")
           |> render_click() =~ "Remove credential?"

    assert view
           |> element("#credential-remove-dialog button[phx-click=confirm_credential_action]")
           |> render_click() =~ "Credential removed"

    assert has_element?(
             view,
             "#credential-status-#{ctx.credential.id}[aria-label='Not configured']"
           )
  end

  test "permission revocation is authoritative on the next mutation", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    view |> element("#credential-edit-#{ctx.credential.id}") |> render_click()
    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)

    assert view
           |> form("#credential-form-#{ctx.credential.id}", credential: %{api_key: "DENIED"})
           |> render_submit() =~ "permission"

    refute render(view) =~ "DENIED"
    refute has_element?(view, "#credential-form-#{ctx.credential.id}")
    assert has_element?(view, "#flash-error.zaq-feedback-banner.zaq-danger", "permission")
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

    assert has_element?(view, "#credential-edit-#{oauth_id}.zaq-btn-secondary", "Connect")

    html = view |> element("#credential-edit-#{oauth_id}") |> render_click()
    assert html =~ "Add AI: Personal Codex"
    view |> element("#credential-oauth-#{oauth_id}") |> render_click()
    assert_push_event(view, "open_oauth_popup", %{url: url})
    assert url =~ "https://auth.openai.com/oauth/authorize"

    html =
      render_hook(view, "oauth_popup_result", %{"status" => "success", "secret" => "IGNORED"})

    assert html =~ "Connection status refreshed"
    refute html =~ "IGNORED"
    refute has_element?(view, "#credential-form-dialog")
    assert has_element?(view, "#credential-status-#{oauth_id}[aria-label='Not configured']")
  end

  test "opening the credential modal rejects unauthorized, unknown and disabled credentials",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    render_click(view, "open_credential_modal", %{"id" => to_string(ctx.credential.id)})
    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-form-dialog")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert_absent_status(ctx)

    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    for id <- ["-1", "not-an-id"] do
      {:ok, rejection_view, _} = live(ctx.conn, "/people/credentials")
      render_click(rejection_view, "open_credential_modal", %{"id" => id})
      assert_error_flash(rejection_view, "You do not have permission to manage credentials.")
      refute has_element?(rejection_view, "#credential-form-dialog")
      refute has_element?(rejection_view, "#credential-revoke-dialog")
      refute has_element?(rejection_view, "#credential-remove-dialog")
      assert_absent_status(ctx)
    end

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "RETAINED_DISABLED_SECRET"
      })

    {:ok, _} = Connect.update_credential(ctx.credential, %{personal_credential_policy: :disabled})
    {:ok, view, html} = live(ctx.conn, "/people/credentials")
    refute html =~ "RETAINED_DISABLED_SECRET"

    render_click(view, "open_credential_modal", %{"id" => to_string(ctx.credential.id)})
    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-form-dialog")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert has_element?(view, "#credential-remove-#{ctx.credential.id}")
    assert {:ok, %{credential_id: id, status: "active"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  test "opening credential actions rejects unsafe transitions", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "ACTION_SECRET"
      })

    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    render_click(view, "open_credential_action", %{
      "id" => to_string(ctx.credential.id),
      "action" => "remove"
    })

    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert {:ok, %{credential_id: id, status: "active"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  test "opening credential actions rejects unknown, absent and revoked transitions", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    for {id, action} <- [{"-1", "remove"}, {to_string(ctx.credential.id), "remove"}] do
      {:ok, rejection_view, _} = live(ctx.conn, "/people/credentials")
      render_click(rejection_view, "open_credential_action", %{"id" => id, "action" => action})
      assert_error_flash(rejection_view, "You do not have permission to manage credentials.")
      refute has_element?(rejection_view, "#credential-revoke-dialog")
      refute has_element?(rejection_view, "#credential-remove-dialog")
      assert_absent_status(ctx)
    end

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "REVOKED_SECRET"
      })

    {:ok, _} = Connect.revoke_credential_grant(ctx.credential, {:person, ctx.person.id})
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    render_click(view, "open_credential_action", %{
      "id" => to_string(ctx.credential.id),
      "action" => "revoke"
    })

    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert {:ok, %{credential_id: id, status: "revoked"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  test "cancelling revoke and remove keeps persisted authentication", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "CANCEL_SECRET"
      })

    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    view |> element("#credential-revoke-#{ctx.credential.id}") |> render_click()
    assert has_element?(view, "#credential-revoke-dialog")

    view
    |> element("#credential-revoke-dialog button[phx-click=close_credential_action]", "Cancel")
    |> render_click()

    refute has_element?(view, "#credential-revoke-dialog")
    assert has_element?(view, "#credential-status-#{ctx.credential.id}[aria-label='Configured']")
    assert {:ok, %{credential_id: id, status: "active"}} = grant_status(ctx)
    assert id == ctx.credential.id

    view |> element("#credential-remove-#{ctx.credential.id}") |> render_click()
    assert has_element?(view, "#credential-remove-dialog")

    view
    |> element("#credential-remove-dialog button[phx-click=close_credential_action]", "Cancel")
    |> render_click()

    refute has_element?(view, "#credential-remove-dialog")
    refute render(view) =~ "CANCEL_SECRET"
    refute has_element?(view, "#flash-info", "Credential revoked")
    refute has_element?(view, "#flash-info", "Credential removed")
    assert {:ok, %{credential_id: id, status: "active"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  test "confirmation and unsupported credential events fail closed", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    render_click(view, "confirm_credential_action", %{
      "action" => "remove",
      "id" => to_string(ctx.credential.id)
    })

    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert_absent_status(ctx)

    {:ok, unexpected_view, _} = live(ctx.conn, "/people/credentials")
    render_click(unexpected_view, "unexpected_credential_event", %{})
    assert_error_flash(unexpected_view, "You do not have permission to manage credentials.")
    refute has_element?(unexpected_view, "#credential-revoke-dialog")
    refute has_element?(unexpected_view, "#credential-remove-dialog")

    {:ok, unsupported_view, _} = live(ctx.conn, "/people/credentials")

    render_click(unsupported_view, "open_credential_action", %{
      "id" => to_string(ctx.credential.id),
      "action" => "delete_all"
    })

    assert_error_flash(unsupported_view, "You do not have permission to manage credentials.")
    refute has_element?(unsupported_view, "#credential-revoke-dialog")
    refute has_element?(unsupported_view, "#credential-remove-dialog")
    assert_absent_status(ctx)
  end

  test "OAuth rejects read-only and non-OAuth credentials", ctx do
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    render_click(view, "connect_oauth", %{"id" => to_string(ctx.credential.id)})
    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-form-dialog")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")

    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    render_click(view, "connect_oauth", %{"id" => to_string(ctx.credential.id)})
    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute has_element?(view, "#credential-form-dialog")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert_absent_status(ctx)
  end

  test "OAuth lookup and Engine failures use the safe generic failure", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    render_click(view, "connect_oauth", %{"id" => "-1"})
    assert_error_flash(view, "Unable to start OAuth. Please try again.")
    assert has_element?(view, "#credential-#{ctx.credential.id}")

    oauth_id = create_oauth_credential().connect_credential_id
    mounted = mount_credentials(ctx, MapSet.new([:access_profile, :manage_credentials]))

    {:noreply, opened} =
      CredentialsLive.handle_event(
        "open_credential_modal",
        %{"id" => to_string(oauth_id)},
        mounted
      )

    assert %{credential_id: ^oauth_id, auth_kind: "oauth2"} = opened.assigns.credential_modal

    before =
      Repo.aggregate(
        Ecto.Query.from(a in OAuthAttempt, where: a.credential_id == ^oauth_id),
        :count
      )

    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)

    {:noreply, result} =
      CredentialsLive.handle_event("connect_oauth", %{"id" => to_string(oauth_id)}, opened)

    assert_normalized_error(result, "Unable to start OAuth. Please try again.")
    assert render_credentials(result) =~ "credential-form-dialog"

    assert {:ok, %{credential_id: ^oauth_id, status: "absent"}} =
             Connect.get_credential_grant_status(
               Connect.get_credential!(oauth_id),
               {:person, ctx.person.id}
             )

    after_count =
      Repo.aggregate(
        Ecto.Query.from(a in OAuthAttempt, where: a.credential_id == ^oauth_id),
        :count
      )

    assert after_count == before
  end

  test "a blocked OAuth popup reloads authoritative state", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "POPUP_SECRET"
      })

    render_hook(view, "oauth_popup_blocked", %{})
    assert_error_flash(view, "The OAuth window was blocked. Allow popups and try again.")
    assert has_element?(view, "#credential-status-#{ctx.credential.id}[aria-label='Configured']")
  end

  test "mutations reject read-only and invalid material or IDs", ctx do
    {:ok, view, _} = live(ctx.conn, "/people/credentials")

    render_submit(view, "save_api_key", %{
      "credential_id" => to_string(ctx.credential.id),
      "credential" => %{"api_key" => "DENIED_PERSON_SECRET"}
    })

    assert_error_flash(view, "You do not have permission to manage credentials.")
    refute render(view) =~ "DENIED_PERSON_SECRET"
    assert_absent_status(ctx)

    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    {:ok, view, _} = live(ctx.conn, "/people/credentials")
    view |> element("#credential-edit-#{ctx.credential.id}") |> render_click()

    render_submit(view, "save_api_key", %{
      "credential_id" => to_string(ctx.credential.id),
      "credential" => %{"api_key" => ""}
    })

    assert_error_flash(view, "Unable to update the credential. Please try again.")
    assert has_element?(view, "#credential-form-dialog")
    assert_secret_input_blank(view, ctx.credential.id)
    refute has_element?(view, "#flash-info", "Credential saved")
    refute has_element?(view, "#credential-revoke-dialog")
    refute has_element?(view, "#credential-remove-dialog")
    assert_absent_status(ctx)

    for id <- ["#{ctx.credential.id}junk", "-1"] do
      {:ok, rejection_view, _} = live(ctx.conn, "/people/credentials")

      render_submit(rejection_view, "save_api_key", %{
        "credential_id" => id,
        "credential" => %{"api_key" => "LOOKUP_SECRET"}
      })

      assert_error_flash(rejection_view, "Unable to update the credential. Please try again.")
      refute has_element?(rejection_view, "#credential-revoke-dialog")
      refute has_element?(rejection_view, "#credential-remove-dialog")
      assert_absent_status(ctx)
    end
  end

  test "invalid sessions redirect and unavailable lists recover on retry", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    mounted = mount_credentials(ctx, MapSet.new([:access_profile, :manage_credentials]))
    {:ok, _} = PeopleAuth.revoke_session(ctx.token)
    {:noreply, redirected} = CredentialsLive.handle_event("retry", %{}, mounted)
    assert redirected.redirected == {:redirect, %{status: 302, to: "/people/login"}}

    {:ok, empty_session} =
      CredentialsLive.mount(%{}, %{}, callback_socket(ctx, MapSet.new([:access_profile])))

    assert empty_session.redirected == {:redirect, %{status: 302, to: "/people/login"}}

    {:ok, challenge} = PeopleAuth.issue_challenge(ctx.person, ctx.challenge_ip)

    {:ok, %{token: fresh_token}} =
      PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

    fresh_ctx = %{ctx | token: fresh_token}
    {:ok, _} = System.set_config("people_access.session_lifetime_seconds", "broken")
    unavailable = mount_credentials(fresh_ctx, MapSet.new([:access_profile, :manage_credentials]))
    assert unavailable.assigns.credentials == []
    assert unavailable.assigns.manageable == false
    assert_normalized_error(unavailable, "Credentials are unavailable. Please try again.")
    html = render_credentials(unavailable)
    assert html =~ "No personal credentials available"
    refute html =~ "credential-edit-"
    refute html =~ "credential-remove-"

    {:ok, _} = System.set_config("people_access.session_lifetime_seconds", "604800")
    {:noreply, recovered} = CredentialsLive.handle_event("retry", %{}, unavailable)
    assert Enum.any?(recovered.assigns.credentials, &(&1.credential_id == ctx.credential.id))
    assert Enum.any?(recovered.assigns.credentials, &(&1.credential_id == ctx.optional.id))
    refute Enum.any?(recovered.assigns.credentials, &(&1.credential_id == ctx.disabled.id))
    assert recovered.assigns.manageable
    html = render_credentials(recovered)
    assert html =~ "credential-edit-#{ctx.credential.id}"
    assert html =~ "credential-edit-#{ctx.optional.id}"
  end

  test "permission defaults remain read-only for malformed values", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    expected_ids = MapSet.new([ctx.credential.id, ctx.optional.id])

    check all(
            permissions <-
              one_of([
                constant(nil),
                list_of(member_of([:access_profile, :manage_credentials, :view_history]),
                  max_length: 4
                ),
                optional_map(%{
                  access_profile: boolean(),
                  manage_credentials: boolean()
                }),
                member_of([
                  MapSet.new(),
                  MapSet.new([:access_profile]),
                  MapSet.new([:manage_credentials])
                ])
              ]),
            max_runs: 20
          ) do
      socket = mount_credentials(ctx, permissions)
      assert MapSet.new(Enum.map(socket.assigns.credentials, & &1.credential_id)) == expected_ids
      refute socket.assigns.manageable

      {:noreply, denied} =
        CredentialsLive.handle_event(
          "save_api_key",
          %{
            "credential_id" => to_string(ctx.credential.id),
            "credential" => %{"api_key" => "PROPERTY_SECRET"}
          },
          socket
        )

      assert_normalized_error(denied, "You do not have permission to manage credentials.")
      assert_absent_status(ctx)
    end

    socket =
      callback_socket(ctx, MapSet.new([:access_profile]))
      |> Map.update!(:assigns, &Map.delete(&1, :person_permissions))

    refute Map.has_key?(socket.assigns, :person_permissions)
    {:ok, socket} = CredentialsLive.mount(%{}, %{"person_session_token" => ctx.token}, socket)
    refute socket.assigns.manageable

    {:noreply, denied} =
      CredentialsLive.handle_event(
        "save_api_key",
        %{
          "credential_id" => to_string(ctx.credential.id),
          "credential" => %{"api_key" => "MISSING_PERMISSION_SECRET"}
        },
        socket
      )

    assert_normalized_error(denied, "You do not have permission to manage credentials.")
    assert_absent_status(ctx)
  end

  test "expired own grants render as Expired with management controls", ctx do
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        api_key: "EXPIRED_PERSON_SECRET"
      })

    grant =
      Repo.get_by!(Grant,
        credential_id: ctx.credential.id,
        owner_type: "person",
        owner_id: ctx.person.id,
        resource_type: "connect_credential",
        resource_id: to_string(ctx.credential.id)
      )

    grant
    |> Ecto.Changeset.change(expires_at: ~U[2000-01-01 00:00:00Z])
    |> Repo.update!()

    {:ok, view, html} = live(ctx.conn, "/people/credentials")

    assert has_element?(
             view,
             "#credential-status-#{ctx.credential.id}[aria-label='Expired'].zaq-pill--elevated",
             "Expired"
           )

    refute has_element?(view, "#credential-status-#{ctx.credential.id}.zaq-pill--success")
    refute has_element?(view, "#credential-status-#{ctx.credential.id}.zaq-pill--danger")
    assert has_element?(view, "#credential-edit-#{ctx.credential.id}")
    assert has_element?(view, "#credential-revoke-#{ctx.credential.id}")
    assert has_element?(view, "#credential-remove-#{ctx.credential.id}")
    refute html =~ "EXPIRED_PERSON_SECRET"
    assert {:ok, %{credential_id: id, status: "expired"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  defp callback_socket(ctx, permissions) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_person: ctx.person,
        person_permissions: permissions
      }
    }
  end

  defp mount_credentials(ctx, permissions) do
    {:ok, socket} =
      CredentialsLive.mount(
        %{},
        %{"person_session_token" => ctx.token},
        callback_socket(ctx, permissions)
      )

    socket
  end

  defp grant_status(ctx) do
    Connect.get_credential_grant_status(ctx.credential, {:person, ctx.person.id})
  end

  defp assert_absent_status(ctx) do
    assert {:ok, %{credential_id: id, status: "absent"}} = grant_status(ctx)
    assert id == ctx.credential.id
  end

  defp render_credentials(socket), do: rendered_to_string(CredentialsLive.render(socket.assigns))

  defp assert_error_flash(view, expected) do
    document = LazyHTML.from_fragment(render(view))
    actual = document |> LazyHTML.query("#flash-error") |> LazyHTML.text()
    assert normalize_text(actual) == normalize_text(expected)
  end

  defp assert_normalized_error(socket, expected) do
    assert normalize_text(Phoenix.Flash.get(socket.assigns.flash, :error)) ==
             normalize_text(expected)
  end

  defp assert_secret_input_blank(view, credential_id) do
    document = LazyHTML.from_fragment(render(view))
    inputs = LazyHTML.query(document, "#credential-api-key-#{credential_id}")
    assert Enum.count(inputs) == 1
    assert LazyHTML.attribute(inputs, "value") in [[], [""]]
  end

  defp normalize_text(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp create_oauth_credential do
    {:ok, oauth} =
      System.create_ai_provider_credential(%{
        name: "Personal Codex Failure",
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

    oauth
  end
end
