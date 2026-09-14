defmodule Zaq.Accounts.PeopleAuthTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties
  alias Plug.Crypto.KeyGenerator

  alias Zaq.Accounts.{
    People,
    PeopleAuth,
    PeoplePermissionGrant,
    PeoplePermissions,
    PersonLoginChallenge,
    PersonSession
  }

  setup do
    Repo.delete_all(PeoplePermissionGrant)
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, person} = People.create_person(%{full_name: "Authentication person"})

    {:ok, _} =
      Zaq.System.save_people_access_config(%{
        otp_send_person_limit: 1000,
        otp_send_ip_limit: 1000
      })

    %{person: person, ip: {127, 0, div(rem(person.id, 65_536), 256), rem(person.id, 256)}}
  end

  test "failed delivery invalidates only its challenge, never a newer replacement", %{
    person: person,
    ip: ip
  } do
    {:ok, first} = PeopleAuth.issue_challenge(person, ip)
    {:ok, second} = PeopleAuth.issue_challenge(person, ip)
    assert {:ok, 0} = PeopleAuth.invalidate_challenge(first.challenge_id)
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(first.challenge_id)
    assert {:ok, descriptor} = PeopleAuth.challenge_status(second.challenge_id)
    assert descriptor == Map.take(second, [:challenge_id, :expires_at])
    assert {:ok, 1} = PeopleAuth.invalidate_challenge(second.challenge_id)
    assert {:ok, 0} = PeopleAuth.invalidate_challenge(second.challenge_id)
    assert {:ok, 0} = PeopleAuth.invalidate_challenge(Ecto.UUID.generate())
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(second.challenge_id)
  end

  test "issue returns only opaque challenge metadata and a trusted delivery code; verify mints one digest-only session",
       %{person: person, ip: ip} do
    assert {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    assert Enum.sort(Map.keys(issued)) == [:challenge_id, :code, :expires_at]
    assert issued.code =~ ~r/\A[0-9]{8}\z/
    row = Repo.get!(PersonLoginChallenge, issued.challenge_id)
    assert byte_size(row.token_digest) == 32
    refute row.token_digest == issued.code

    assert {:ok, %{token: token, session: session}} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    refute Map.has_key?(session, :token_digest)
    assert Repo.get!(PersonSession, session.id).token_digest == :crypto.hash(:sha256, token)
    assert {:ok, %{person: current, session: ^session}} = PeopleAuth.authenticate(token)
    assert current.id == person.id

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    assert Repo.aggregate(PersonSession, :count) == 1
  end

  test "Engine issuance and persisted verification remain available without Channels", %{
    person: person,
    ip: ip
  } do
    channels = Zaq.Channels.Supervisor
    engine_pid = Process.whereis(Zaq.Engine.Supervisor)
    limiter_pid = Process.whereis(Zaq.People.AuthRateLimiter)
    assert is_pid(engine_pid)
    assert is_pid(limiter_pid)
    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, channels)

    try do
      assert Process.whereis(channels) == nil
      assert Process.whereis(Zaq.Channels.PeopleAuthRateLimiter) == nil
      assert Process.whereis(Zaq.Engine.Supervisor) == engine_pid
      assert Process.whereis(Zaq.People.AuthRateLimiter) == limiter_pid

      assert {:ok, successful} = PeopleAuth.issue_challenge(person, ip)

      assert {:ok, %{token: token}} =
               PeopleAuth.verify_challenge(successful.challenge_id, successful.code)

      assert {:ok, %{person: authenticated}} = PeopleAuth.authenticate(token)
      assert authenticated.id == person.id

      assert {:ok, _} =
               Zaq.System.save_people_access_config(%{
                 otp_send_person_limit: 2,
                 otp_max_attempts: 1
               })

      assert {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
      assert {:error, {:rate_limited, _}} = PeopleAuth.issue_challenge(person, ip)

      assert {:error, :invalid_challenge} =
               PeopleAuth.verify_challenge(issued.challenge_id, "bad")

      assert Repo.get!(PersonLoginChallenge, issued.challenge_id).attempt_count == 1

      assert {:error, :invalid_challenge} =
               PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

      assert Process.whereis(channels) == nil
      assert Process.whereis(Zaq.Engine.Supervisor) == engine_pid
      assert Process.whereis(Zaq.People.AuthRateLimiter) == limiter_pid
    after
      {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, channels)
      _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    end
  end

  test "successful backend issuance never spends the Channels failure budget", %{
    person: person,
    ip: ip
  } do
    ingress = Zaq.Channels.PeopleAuthRateLimiter
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    assert {:ok, _} = PeopleAuth.issue_challenge(person, ip)
    assert {:ok, _} = PeopleAuth.issue_challenge(person, ip)
    assert :ok = ingress.check_identification(ip)
  end

  test "malformed and wrong guesses commit attempts and current max applies in flight", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)

    for invalid <- [nil, %{}, "abcdef", <<255>>] do
      assert {:error, :invalid_challenge} =
               PeopleAuth.verify_challenge(issued.challenge_id, invalid)
    end

    assert Repo.get!(PersonLoginChallenge, issued.challenge_id).attempt_count == 4
    assert {:ok, _} = Zaq.System.save_people_access_config(%{otp_max_attempts: 4})

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    assert Repo.get!(PersonLoginChallenge, issued.challenge_id).attempt_count == 4
  end

  test "replacement invalidates every unfinished challenge and explicit invalidation is idempotent",
       %{person: person, ip: ip} do
    {:ok, first} = PeopleAuth.issue_challenge(person, ip)

    Repo.get!(PersonLoginChallenge, first.challenge_id)
    |> PersonLoginChallenge.changeset(%{
      inserted_at: DateTime.add(DateTime.utc_now(:second), -600),
      expires_at: DateTime.add(DateTime.utc_now(:second), -300)
    })
    |> Repo.update!()

    {:ok, second} = PeopleAuth.issue_challenge(person.id, ip)
    assert Repo.get!(PersonLoginChallenge, first.challenge_id).invalidated_at

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(first.challenge_id, first.code)

    assert {:ok, 1} = PeopleAuth.invalidate_challenges(person)
    assert {:ok, 0} = PeopleAuth.invalidate_challenges(person)

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(second.challenge_id, second.code)
  end

  test "current identity, status and grant are required at issuance and authentication", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
    assert {:error, :ineligible} = PeopleAuth.issue_challenge(person, ip)
    assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, _} = People.update_person(person, %{status: "inactive"})
    assert {:error, :ineligible} = PeopleAuth.issue_challenge(person, ip)
    assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)
    {:ok, _} = People.delete_person(person)
    assert {:error, :not_found} = PeopleAuth.issue_challenge(person, ip)
    assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)
  end

  test "verification rejects newly ineligible person without granting a session", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    assert Repo.aggregate(PersonSession, :count) == 0
  end

  test "corrupt config fails closed but revocation still works", %{person: person, ip: ip} do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
    {:ok, next} = PeopleAuth.issue_challenge(person, ip)
    {:ok, _} = Zaq.System.set_config("people_access.otp_max_attempts", "bad")
    assert {:error, {:invalid_people_access_config, _}} = PeopleAuth.issue_challenge(person, ip)

    assert {:error, {:invalid_people_access_config, _}} =
             PeopleAuth.verify_challenge(next.challenge_id, next.code)

    assert {:error, {:invalid_people_access_config, _}} = PeopleAuth.authenticate(auth.token)
    assert {:ok, 1} = PeopleAuth.revoke_all_sessions(person)
    assert {:ok, 1} = PeopleAuth.invalidate_challenges(person)
  end

  test "session listing, touch and revocation distinguish session id from bearer token", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
    assert {:ok, [session]} = PeopleAuth.list_sessions(person)
    assert session.id == auth.session.id
    assert {:error, :invalid_session} = PeopleAuth.authenticate(session.id)
    assert {:ok, touched} = PeopleAuth.touch_session(auth.token)
    assert touched.last_seen_at
    assert touched.expires_at == session.expires_at
    assert {:ok, _} = PeopleAuth.revoke_session(auth.token)
    assert {:ok, _} = PeopleAuth.revoke_session(auth.token)
    assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)
    assert {:error, :invalid_session} = PeopleAuth.touch_session(auth.token)
    assert {:ok, 0} = PeopleAuth.revoke_all_sessions(person)
  end

  test "invalid inputs and missing identities never grant access", %{ip: ip} do
    for invalid <- [nil, %{}, [], 0, -1, "junk", <<255>>, String.duplicate("!", 43)] do
      assert {:error, _} = PeopleAuth.issue_challenge(invalid, ip)
      assert {:error, _} = PeopleAuth.verify_challenge(invalid, "12345678")
      assert {:error, _} = PeopleAuth.authenticate(invalid)
      assert {:error, _} = PeopleAuth.revoke_session(invalid)
      assert {:error, _} = PeopleAuth.touch_session(invalid)
      assert {:error, _} = PeopleAuth.list_sessions(invalid)
      assert {:error, _} = PeopleAuth.invalidate_challenges(invalid)
      assert {:error, _} = PeopleAuth.revoke_all_sessions(invalid)
    end

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(Ecto.UUID.generate(), "12345678")

    assert {:error, :invalid_session} =
             PeopleAuth.authenticate(
               Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
             )
  end

  test "existing secret rotation invalidates codes, not independent session digests", %{
    person: person,
    ip: ip
  } do
    {:ok, first} = PeopleAuth.issue_challenge(person, ip)
    {:ok, auth} = PeopleAuth.verify_challenge(first.challenge_id, first.code)
    {:ok, next} = PeopleAuth.issue_challenge(person, ip)

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(next.challenge_id, next.code,
               secret_key_base: String.duplicate("r", 64)
             )

    assert {:ok, _} = PeopleAuth.authenticate(auth.token)

    for invalid <- [nil, "", 123] do
      assert {:error, :invalid_signing_configuration} =
               PeopleAuth.issue_challenge(person, ip, secret_key_base: invalid)

      assert {:error, :invalid_signing_configuration} =
               PeopleAuth.verify_challenge(next.challenge_id, next.code, secret_key_base: invalid)
    end
  end

  test "HMAC has explicit domain separation and is bound to the opaque challenge", %{
    person: person,
    ip: ip
  } do
    key_base = String.duplicate("k", 64)
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip, secret_key_base: key_base)

    key =
      KeyGenerator.generate(key_base, "zaq:people-auth:otp-verification:v1", length: 32)

    expected = :crypto.mac(:hmac, :sha256, key, issued.challenge_id <> ":" <> issued.code)
    assert Repo.get!(PersonLoginChallenge, issued.challenge_id).token_digest == expected

    assert {:ok, _} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code,
               secret_key_base: key_base
             )
  end

  test "expiry is fixed and checked independently of later duration changes", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, _} = Zaq.System.save_people_access_config(%{otp_validity_seconds: 1})
    assert Repo.get!(PersonLoginChallenge, issued.challenge_id).expires_at == issued.expires_at

    assert {:error, :invalid_challenge} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code,
               clock: Zaq.TestSupport.PeopleAuthFutureClock
             )

    assert Repo.get!(PersonLoginChallenge, issued.challenge_id).attempt_count == 0
    {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
    {:ok, _} = Zaq.System.save_people_access_config(%{session_lifetime_seconds: 1})
    assert {:ok, _} = PeopleAuth.authenticate(auth.token)

    assert {:error, :invalid_session} =
             PeopleAuth.authenticate(auth.token, clock: Zaq.TestSupport.PeopleAuthFutureClock)

    assert {:error, :invalid_session} =
             PeopleAuth.touch_session(auth.token, clock: Zaq.TestSupport.PeopleAuthFutureClock)
  end

  test "session insertion failure rolls back consumed challenge and allows retry", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    # Real database rejection, scoped to this sandbox transaction. No production hook.
    Repo.query!("ALTER TABLE person_sessions DROP CONSTRAINT person_sessions_expiry_check")

    Repo.query!(
      "ALTER TABLE person_sessions ADD CONSTRAINT person_sessions_expiry_check CHECK (false) NOT VALID"
    )

    assert {:error, %Ecto.Changeset{}} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    refute Repo.get!(PersonLoginChallenge, issued.challenge_id).consumed_at
    Repo.query!("ALTER TABLE person_sessions DROP CONSTRAINT person_sessions_expiry_check")
    assert {:ok, _} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
  end

  test "issuance does not invalidate an existing challenge when send budget denies", %{
    person: person,
    ip: ip
  } do
    {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_person_limit: 1})
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    assert {:error, {:rate_limited, _}} = PeopleAuth.issue_challenge(person, ip)
    refute Repo.get!(PersonLoginChallenge, issued.challenge_id).invalidated_at
    assert {:ok, _} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
  end

  test "unrepresentable expiry fails without consuming the previous challenge", %{
    person: person,
    ip: ip
  } do
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)

    {:ok, _} =
      Zaq.System.save_people_access_config(%{session_lifetime_seconds: Integer.pow(2, 100)})

    assert {:error, :invalid_expiry} =
             PeopleAuth.verify_challenge(issued.challenge_id, issued.code)

    refute Repo.get!(PersonLoginChallenge, issued.challenge_id).consumed_at
  end

  test "raw authentication material never enters Repo telemetry parameters", %{
    person: person,
    ip: ip
  } do
    parent = self()
    handler = "auth-telemetry-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == parent, do: send(parent, {:auth_query, :erlang.term_to_binary(metadata)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
    {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
    assert {:ok, _} = PeopleAuth.authenticate(auth.token)
    queries = drain_queries([])
    assert queries != []
    assert Enum.all?(queries, &(not String.contains?(&1, [issued.code, auth.token])))
  end

  defp drain_queries(acc) do
    receive do
      {:auth_query, query} -> drain_queries([query | acc])
    after
      0 -> acc
    end
  end

  property "generated eight ASCII digits verify with whitespace/hyphens removed", %{
    person: person,
    ip: ip
  } do
    check all(separator <- member_of([" ", "-", "\t", "\n", " \t- "]), max_runs: 100) do
      {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
      assert issued.code =~ ~r/\A[0-9]{8}\z/
      normalized_input = issued.code |> String.graphemes() |> Enum.join(separator)
      assert {:ok, _} = PeopleAuth.verify_challenge(issued.challenge_id, normalized_input)
    end
  end
end
