defmodule Zaq.Engine.Connect.DeviceAttemptsTestHTTPClient do
  def post(_request_opts) do
    send(Process.whereis(:device_attempts_test_owner), :injected_client_called)
    {:ok, %{status: 200, body: %{"unexpected" => true}}}
  end
end

defmodule Zaq.Engine.Connect.DeviceAttemptsTestRaisingHTTPClient do
  def post(_request_opts) do
    send(Process.whereis(:device_attempts_test_owner), :injected_client_called)
    raise "private transport detail"
  end
end

defmodule Zaq.Engine.Connect.DeviceAttemptsTestOfflineHTTPClient do
  def post(_request_opts) do
    send(Process.whereis(:device_attempts_test_owner), :injected_client_called)
    {:error, :offline}
  end
end

defmodule Zaq.Engine.Connect.DeviceAttemptsTestSlowdownHTTPClient do
  def post(_request_opts) do
    send(Process.whereis(:device_attempts_test_owner), :injected_client_called)
    {:ok, %{status: 429, body: %{"error" => "slow_down"}}}
  end
end

defmodule Zaq.Engine.Connect.DeviceAttemptsTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions, Person, PersonSession}
  alias Zaq.Engine.{Api, Connect, PeopleAuthGateway}

  alias Zaq.Engine.Connect.{
    Credential,
    DeviceAttempt,
    DeviceAttempts,
    DeviceAttemptsTestHTTPClient,
    DeviceAttemptsTestOfflineHTTPClient,
    DeviceAttemptsTestRaisingHTTPClient,
    DeviceAttemptsTestSlowdownHTTPClient,
    DeviceWorker,
    Grant
  }

  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP, PersonOAuth}

  @opts [config: ConnectOAuthAttemptConfig]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    :ok
  end

  defp attrs do
    %{
      name: "device-#{Ecto.UUID.generate()}",
      provider: "openai_codex",
      auth_kind: "oauth2",
      secret_binding: :grant,
      personal_credential_policy: :required,
      client_id: "codex-client",
      metadata: %{
        "auth_profile" => "openai_chatgpt_codex",
        "token_url" => "https://auth.openai.com/oauth/token"
      }
    }
  end

  defp start(interval \\ 900) do
    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      assert conn.request_path == "/api/accounts/deviceauth/usercode"

      Req.Test.json(conn, %{
        "device_auth_id" => "PRIVATE_DEVICE",
        "user_code" => "ABCD-EFGH",
        "interval" => interval
      })
    end)

    assert {:ok, dto} = DeviceAttempts.start_global_configuration(nil, attrs(), @opts)
    attempt = Repo.get!(DeviceAttempt, dto.attempt_id)
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
    Req.Test.allow(ConnectOAuthAttemptHTTP, self(), pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {dto, attempt, pid}
  end

  test "initiation encrypts all transient material and rejects cross-owner status" do
    {dto, attempt, _} = start()
    assert dto.status == "pending"
    assert dto.user_code == "ABCD-EFGH"
    refute inspect(dto) =~ "PRIVATE_DEVICE"
    refute inspect(attempt) =~ "PRIVATE_DEVICE"

    assert {:error, :not_found} =
             DeviceAttempts.status(dto.attempt_id, {"person", 1, "wrong"}, @opts)

    assert %{rows: [[material, candidate, code]]} =
             Repo.query!(
               "SELECT device_material, candidate_config, user_code FROM connect_device_attempts WHERE id=$1",
               [attempt.id]
             )

    assert Enum.all?([material, candidate, code], &String.starts_with?(&1, "enc:"))
    assert {:ok, %{status: "pending"}} = DeviceAttempts.status(attempt.id, :org, @opts)
  end

  test "approval exchanges verifier and commits canonical grant and success together" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      assert conn.request_path == "/api/accounts/deviceauth/token"
      Req.Test.json(conn, %{"authorization_code" => "CODE", "code_verifier" => "VERIFIER"})
    end)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      assert form["redirect_uri"] == "https://auth.openai.com/deviceauth/callback"
      assert form["code_verifier"] == "VERIFIER"

      Req.Test.json(conn, %{
        "access_token" => "ACCESS",
        "refresh_token" => "REFRESH",
        "expires_in" => 3600
      })
    end)

    assert {:ok, %{status: "active", result_credential_id: id}} =
             DeviceAttempts.poll(attempt.id, pid, @opts)

    assert Repo.get!(Credential, id).provider == "openai_codex"
    assert Repo.get_by!(Grant, credential_id: id, owner_type: "org").access_token == "ACCESS"
    Process.exit(pid, :kill)

    assert {:ok, %{status: "active", credential_id: ^id}} =
             DeviceAttempts.status(attempt.id, :org, @opts)

    assert {:ok, %{status: "active"}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
    assert Repo.get!(DeviceAttempt, attempt.id).device_material == nil
  end

  test "pending timing comes from behavior; cancellation is terminal and erases secrets" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow_down"})
    end)

    assert {:ok, %{status: "pending", interval: 905}} =
             DeviceAttempts.poll(attempt.id, pid, @opts)

    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.poll(attempt.id, pid, @opts)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)

    refute Repo.exists?(Credential)
  end

  test "initiation failures are sanitized and erase persisted transient material" do
    cases = [
      {DeviceAttemptsTestHTTPClient, :malformed},
      {DeviceAttemptsTestRaisingHTTPClient, :raise},
      {DeviceAttemptsTestOfflineHTTPClient, :offline}
    ]

    Process.register(self(), :device_attempts_test_owner)

    try do
      for {client, label} <- cases do
        ids_before = Repo.all(from a in DeviceAttempt, select: a.id) |> MapSet.new()

        assert {:error, :oauth_failed} =
                 DeviceAttempts.start_global_configuration(
                   nil,
                   attrs(),
                   Keyword.put(@opts, :device_http_client, client)
                 )

        assert_receive :injected_client_called
        ids_after = Repo.all(from a in DeviceAttempt, select: a.id) |> MapSet.new()
        [new_id] = MapSet.difference(ids_after, ids_before) |> MapSet.to_list()
        attempt = Repo.get!(DeviceAttempt, new_id)
        assert attempt.status == "failed", "#{label} initiation must be terminal"
        assert %{device_material: nil, candidate_config: nil, user_code: nil} = attempt
        refute Repo.exists?(Grant)
      end
    after
      Process.unregister(:device_attempts_test_owner)
    end
  end

  test "slowdown at the maximum interval and poll transport exceptions fail safely" do
    {_dto, attempt, pid} = start()
    attempt = Repo.update!(Ecto.Changeset.change(attempt, interval: 3600))
    Process.register(self(), :device_attempts_test_owner)

    assert {:ok, %{status: "failed"}} =
             DeviceAttempts.poll(
               attempt.id,
               pid,
               Keyword.put(@opts, :device_http_client, DeviceAttemptsTestSlowdownHTTPClient)
             )

    assert_receive :injected_client_called
    Process.unregister(:device_attempts_test_owner)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)

    refute Repo.exists?(Grant)

    {_dto, attempt, pid} = start()
    Process.register(self(), :device_attempts_test_owner)

    assert {:ok, %{status: "failed"}} =
             DeviceAttempts.poll(
               attempt.id,
               pid,
               Keyword.put(@opts, :device_http_client, DeviceAttemptsTestRaisingHTTPClient)
             )

    assert_receive :injected_client_called
    Process.unregister(:device_attempts_test_owner)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)

    refute Repo.exists?(Grant)
  end

  test "approval without an access token rolls back canonical replacement" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"authorization_code" => "CODE", "code_verifier" => "VERIFIER"})
    end)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"refresh_token" => "NO_ACCESS"})
    end)

    assert {:ok, %{status: "failed"}} = DeviceAttempts.poll(attempt.id, pid, @opts)
    refute Repo.exists?(Credential)
    refute Repo.exists?(Grant)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)
  end

  test "approval without an access token preserves the existing reauthorization grant" do
    {:ok, dto} = Connect.save_credential_configuration(nil, attrs())

    {:ok, _} =
      Connect.replace_credential_grant(dto.credential_id, :org, %{access_token: "OLD_ACCESS"})

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "device_auth_id" => "PRIVATE",
        "user_code" => "CODE",
        "interval" => 900
      })
    end)

    assert {:ok, started} =
             DeviceAttempts.start_global_configuration(dto.credential_id, %{}, @opts)

    attempt = Repo.get!(DeviceAttempt, started.attempt_id)
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
    Req.Test.allow(ConnectOAuthAttemptHTTP, self(), pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"authorization_code" => "CODE", "code_verifier" => "VERIFIER"})
    end)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"refresh_token" => "NO_ACCESS"})
    end)

    assert {:ok, %{status: "failed"}} = DeviceAttempts.poll(attempt.id, pid, @opts)

    assert Repo.get_by!(Grant, credential_id: dto.credential_id, owner_type: "org").access_token ==
             "OLD_ACCESS"
  end

  test "successful exchange without expires_in persists an active grant without expiry" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"authorization_code" => "CODE", "code_verifier" => "VERIFIER"})
    end)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{"access_token" => "NO_EXPIRY"})
    end)

    assert {:ok, %{status: "active", result_credential_id: id}} =
             DeviceAttempts.poll(attempt.id, pid, @opts)

    grant = Repo.get_by!(Grant, credential_id: id, owner_type: "org")
    assert grant.access_token == "NO_EXPIRY"
    assert is_nil(grant.expires_at)
  end

  test "pending response after cancellation does not revive or retain secrets" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      assert {:ok, %{status: "cancelled"}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow_down"})
    end)

    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.poll(attempt.id, pid, @opts)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)
  end

  test "status rejects invalid identities and expires exactly at the deadline" do
    {_dto, attempt, _pid} = start()
    assert {:error, :not_found} = DeviceAttempts.status(17, :org, @opts)
    assert {:error, :not_found} = DeviceAttempts.status(attempt.id, {:person, 17}, @opts)

    assert {:ok, %{status: "expired"}} =
             DeviceAttempts.status(attempt.id, :org, Keyword.put(@opts, :now, attempt.expires_at))

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)
  end

  test "status expires when the clock reaches the deadline between validation and refresh" do
    {_dto, attempt, _pid} = start()
    just_before = DateTime.add(attempt.expires_at, -1, :second)
    calls = start_supervised!({Agent, fn -> 0 end})

    clock = fn ->
      count = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
      if count < 2, do: just_before, else: attempt.expires_at
    end

    assert {:ok, %{status: "expired"}} =
             DeviceAttempts.status(attempt.id, :org, Keyword.put(@opts, :now, clock))

    assert Repo.get!(DeviceAttempt, attempt.id).device_material == nil
  end

  test "a pending attempt without an attached worker becomes interrupted" do
    {_dto, attempt, pid} = start()
    Repo.update!(Ecto.Changeset.change(attempt, worker_pid: nil))
    assert {:ok, %{status: "interrupted"}} = DeviceAttempts.status(attempt.id, :org, @opts)

    assert %{device_material: nil, candidate_config: nil, user_code: nil} =
             Repo.get!(DeviceAttempt, attempt.id)

    Process.exit(pid, :kill)
  end

  test "start encryption and invalid OAuth configuration roll back without attempts" do
    Code.ensure_loaded!(Zaq.TestSupport.ConnectEncryptionConfig)
    before_count = Repo.aggregate(DeviceAttempt, :count)
    opts = [config: Zaq.TestSupport.ConnectEncryptionConfig, encryption_config: []]

    assert {:error, :encryption_failed} =
             DeviceAttempts.start_global_configuration(nil, attrs(), opts)

    assert Repo.aggregate(DeviceAttempt, :count) == before_count

    invalid_attrs = Map.put(attrs(), :metadata, %{})

    assert {:error, :invalid_attempt} =
             DeviceAttempts.start_global_configuration(nil, invalid_attrs, @opts)

    assert Repo.aggregate(DeviceAttempt, :count) == before_count
  end

  test "a second worker cannot replace the attached worker" do
    {_dto, attempt, pid} = start()
    original_worker_pid = attempt.worker_pid

    assert {:error, :normal} =
             DeviceWorker.start_link({attempt.id, @opts})

    assert Repo.get!(DeviceAttempt, attempt.id).worker_pid == original_worker_pid

    assert {:ok, %{status: "pending"}} = DeviceAttempts.status(attempt.id, :org, @opts)
    assert Process.alive?(pid)
  end

  test "worker reschedules slowdown poll and stops after cancellation" do
    parent = self()
    {_dto, attempt, pid} = start()
    Repo.update!(Ecto.Changeset.change(attempt, interval: 1))
    ref = Process.monitor(pid)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      send(parent, :worker_polled)
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow_down"})
    end)

    send(pid, :poll)
    assert_receive :worker_polled, 3_000
    assert :sys.get_state(pid)
    updated = Repo.get!(DeviceAttempt, attempt.id)
    assert updated.status == "pending"
    assert updated.interval == 6
    assert updated.worker_pid == attempt.worker_pid

    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
    send(pid, :poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    assert Repo.get!(DeviceAttempt, attempt.id).device_material == nil
  end

  test "worker death requires explicit restart; duplicate worker cannot attach" do
    {_dto, attempt, pid} = start()
    assert {:error, :invalid_attempt} = DeviceAttempts.attach_worker(attempt.id, self())
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, %{status: "interrupted"}} = DeviceAttempts.status(attempt.id, :org, @opts)
    assert {:error, :invalid_attempt} = DeviceAttempts.attach_worker(attempt.id, self())
    assert Repo.get!(DeviceAttempt, attempt.id).device_material == nil
  end

  test "expiry is exclusive" do
    {_dto, attempt, pid} = start()
    opts = Keyword.put(@opts, :now, attempt.expires_at)
    assert {:ok, %{status: "expired"}} = DeviceAttempts.poll(attempt.id, pid, opts)
    assert Repo.get!(DeviceAttempt, attempt.id).candidate_config == nil
  end

  test "cancellation during provider IO prevents late approval from replacing grants" do
    {_dto, attempt, pid} = start()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      assert {:ok, %{status: "cancelled"}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
      Req.Test.json(conn, %{"authorization_code" => "CODE", "code_verifier" => "VERIFIER"})
    end)

    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.poll(attempt.id, pid, @opts)
    refute Repo.exists?(Credential)
    refute Repo.exists?(Grant)
  end

  test "Person starts authenticate, remain session bound, and reject foreign attempts" do
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Device owner"}))
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 33, 1, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    {:ok, dto} = Connect.save_credential_configuration(nil, attrs())
    {:ok, _} = PersonOAuth.associate(dto.credential_id)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "device_auth_id" => "PERSON_DEVICE",
        "user_code" => "PERSON-CODE",
        "interval" => 900
      })
    end)

    assert {:ok, start} =
             PeopleAuthGateway.dispatch(
               %{
                 op: :start_self_credential_device,
                 token: token,
                 credential_id: dto.credential_id
               },
               @opts
             )

    attempt = Repo.get!(DeviceAttempt, start.attempt_id)
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert attempt.owner_id == person.id
    assert {:error, :not_found} = DeviceAttempts.status(attempt.id, :org, @opts)

    assert {:ok, %{attempt_id: id}} =
             PeopleAuthGateway.dispatch(
               %{
                 op: :self_credential_device_current,
                 token: token,
                 credential_id: dto.credential_id
               },
               @opts
             )

    assert id == attempt.id

    assert {:ok, %{attempt_id: ^id, status: "pending"}} =
             PeopleAuthGateway.dispatch(
               %{op: :self_credential_device_status, token: token, attempt_id: id},
               @opts
             )

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(PersonSession, attempt.session_id),
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )

    assert {:ok, %{status: "failed"}} = DeviceAttempts.poll(attempt.id, pid, @opts)
    refute Repo.exists?(from g in Grant, where: g.owner_type == "person")
  end

  test "changed configuration and expired cleanup invalidate pending attempts" do
    {_dto, attempt, pid} = start()
    assert {:ok, 1} = DeviceAttempts.reconcile(now: attempt.expires_at)
    assert Repo.get(DeviceAttempt, attempt.id) == nil
    assert {:error, :not_found} = DeviceAttempts.status(attempt.id, :org, @opts)
    assert {:error, :invalid_attempt} = DeviceAttempts.poll(attempt.id, pid, @opts)
  end

  test "Engine refuses observable device envelopes" do
    event = %Zaq.Event{next_hop: :engine, request: %{op: :status, attempt_id: "unknown"}}

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :connect_device, %{})
  end

  test "temporary worker drives polling without a browser or status request" do
    parent = self()
    {_dto, attempt, pid} = start(1)
    ref = Process.monitor(pid)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      send(parent, :worker_polled)
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "access_denied"})
    end)

    assert_receive :worker_polled, 3_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    assert {:ok, %{status: "denied"}} = DeviceAttempts.status(attempt.id, :org, @opts)
  end

  test "configuration edits invalidate pending reauthorization and preserve the old grant" do
    {:ok, dto} = Connect.save_credential_configuration(nil, attrs())

    {:ok, _} =
      Connect.replace_credential_grant(dto.credential_id, :org, %{access_token: "OLD_ACCESS"})

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "device_auth_id" => "PRIVATE",
        "user_code" => "CODE",
        "interval" => 900
      })
    end)

    assert {:ok, start} = DeviceAttempts.start_global_configuration(dto.credential_id, %{}, @opts)
    attempt = Repo.get!(DeviceAttempt, start.attempt_id)
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    credential = Repo.get!(Credential, dto.credential_id)
    Repo.update!(Ecto.Changeset.change(credential, scopes: ["changed"]))
    assert {:ok, %{status: "failed"}} = DeviceAttempts.status(attempt.id, :org, @opts)

    assert Repo.get_by!(Grant, credential_id: credential.id, owner_type: "org").access_token ==
             "OLD_ACCESS"
  end

  property "terminal interruption/cancellation cannot revert to pending or active" do
    check all(cancel_first <- boolean(), repetitions <- integer(1..4), max_runs: 20) do
      {_dto, attempt, pid} = start()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      if cancel_first, do: DeviceAttempts.cancel(attempt.id, :org, @opts)
      assert {:ok, %{status: status}} = DeviceAttempts.status(attempt.id, :org, @opts)
      assert status in ["cancelled", "interrupted"]

      for _ <- 1..repetitions do
        assert {:ok, %{status: ^status}} = DeviceAttempts.cancel(attempt.id, :org, @opts)
        assert {:ok, %{status: ^status}} = DeviceAttempts.poll(attempt.id, pid, @opts)
      end
    end
  end
end
