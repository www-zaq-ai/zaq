defmodule Zaq.Engine.Connect.DeviceAttemptsTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions, Person, PersonSession}
  alias Zaq.Engine.{Api, Connect, PeopleAuthGateway}
  alias Zaq.Engine.Connect.{Credential, DeviceAttempt, DeviceAttempts, Grant}
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
