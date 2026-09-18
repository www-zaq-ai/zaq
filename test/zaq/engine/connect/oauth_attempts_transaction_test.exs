defmodule Zaq.Engine.Connect.OAuthAttemptsTransactionTest do
  # Actual Oban failure via transaction-local DDL, removed by sandbox rollback.
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, OAuthAttempt, OAuthAttempts}
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP, PersonOAuth}

  setup {Req.Test, :verify_on_exit!}

  test "failed notification insert rolls back final grant while the claim remains consumed" do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    opts = [config: ConnectOAuthAttemptConfig]
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "OAuth transaction"}))

    {:ok, dto} =
      Connect.save_credential_configuration(nil, %{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "client",
        metadata: %{
          "authorize_url" => "https://example.test/auth",
          "token_url" => "https://example.test/token"
        }
      })

    credential = Repo.get!(Credential, dto.credential_id)

    {:ok, original} =
      Connect.replace_credential_grant(credential, {:person, person.id}, %{
        access_token: "previous"
      })

    {:ok, %{authorize_url: url}} = PersonOAuth.start(person, credential.id, opts)
    state = URI.decode_query(URI.parse(url).query)["state"]
    before_jobs = Repo.aggregate(Oban.Job, :count)

    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT oauth_attempt_event_failure CHECK (queue <> 'connect_credential_notifications') NOT VALID"
    )

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"access_token" => "replacement"})
    end)

    params = %{"state" => state, "code" => "code"}
    assert {:error, :invalid_attempt} = OAuthAttempts.finalize_callback("example", params, opts)
    assert {:error, :invalid_attempt} = OAuthAttempts.finalize_callback("example", params, opts)
    assert Repo.get!(Grant, original.grant_id).access_token == "previous"
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
    attempt = Repo.get_by!(OAuthAttempt, credential_id: credential.id)
    refute is_nil(attempt.claimed_at)
    assert is_nil(attempt.pkce_verifier)
  end
end
