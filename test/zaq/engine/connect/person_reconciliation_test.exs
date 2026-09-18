defmodule Zaq.Engine.Connect.PersonReconciliationTest do
  use Zaq.DataCase, async: true
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.System.SecretConfig

  alias Zaq.Engine.Connect.{
    Credential,
    Grant,
    OAuthAttempt,
    PersonLifecycle,
    SecretReconciliationWorker
  }

  test "bounded keyset cleanup preserves literal inactive owners and live new admin candidates" do
    now = DateTime.utc_now()
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "retained"}))

    {:ok, dto} =
      Connect.save_credential_configuration(nil, %{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "api_key",
        secret_binding: :grant,
        personal_credential_policy: :required
      })

    credential = Repo.get!(Credential, dto.credential_id)

    {:ok, kept} =
      Connect.replace_credential_grant(credential, {:person, person.id}, %{api_key: "retained"})

    Repo.update!(Person.update_changeset(person, %{status: "inactive"}))

    orphans =
      for _ <- 1..3 do
        owner = Repo.insert!(Person.changeset(%Person{}, %{full_name: "orphan"}))

        {:ok, grant} =
          Connect.replace_credential_grant(credential, {:person, owner.id}, %{
            api_key: "orphan-secret"
          })

        Repo.delete!(owner)
        grant.grant_id
      end

    live = attempt(now, 600)
    expired = attempt(now, 0)
    claimed = attempt(now, 600, claimed_at: now)
    expired_claim = attempt(now, 0, claimed_at: now)
    Repo.delete_all(Oban.Job)

    assert {:ok, first} = PersonLifecycle.reconcile(limit: 2, now: now)
    assert first.grants_deleted == 2
    assert first.attempts_deleted == 2
    assert first.continuation.grant_id == Enum.at(orphans, 1)
    assert Repo.get(Grant, List.last(orphans))
    refute Repo.get(OAuthAttempt, expired.id)
    refute Repo.get(OAuthAttempt, expired_claim.id)
    assert Repo.get(OAuthAttempt, claimed.id)
    assert Repo.get(OAuthAttempt, live.id)
    assert Repo.get!(Grant, kept.grant_id).api_key == "retained"

    assert {:ok, second} =
             PersonLifecycle.reconcile(limit: 2, now: now, after: first.continuation)

    assert second.grants_deleted == 1
    assert {:ok, %{grants_deleted: 0, attempts_deleted: 0}} = PersonLifecycle.reconcile(now: now)
    assert Repo.aggregate(Oban.Job, :count) == 3
    assert {:ok, %{attempts_deleted: 2}} = PersonLifecycle.reconcile(now: DateTime.add(now, 600))
    refute Repo.get(OAuthAttempt, claimed.id)
    assert :ok = SecretReconciliationWorker.perform(%Oban.Job{args: %{}})
  end

  test "invalid bounds reject without expanding scope" do
    for limit <- [0, -1, 501, "100", nil] do
      assert {:error, :invalid_batch} = PersonLifecycle.reconcile(limit: limit)
    end

    for cursor <- [nil, %{}, %{grant_id: -1, attempt_id: ""}, %{grant_id: 0, attempt_id: nil}] do
      assert {:error, :invalid_batch} = PersonLifecycle.reconcile(after: cursor)
    end

    assert {:error, :invalid_batch} = PersonLifecycle.reconcile(now: nil)
  end

  test "worker uniqueness and telemetry contain counts only; no recursive continuation job" do
    {:ok, first} = %{} |> SecretReconciliationWorker.new() |> Oban.insert()
    {:ok, second} = %{} |> SecretReconciliationWorker.new() |> Oban.insert()
    assert second.conflict?
    assert first.id == second.id
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:zaq, :connect, :secret_reconciliation],
        &__MODULE__.capture/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert :ok = SecretReconciliationWorker.perform(first)

    assert_receive {:cleanup,
                    %{grants_deleted: 0, attempts_deleted: 0, duration: duration} = measurements,
                    %{outcome: :ok} = metadata}

    assert is_integer(duration) and duration >= 0
    assert map_size(measurements) == 3
    assert map_size(metadata) == 1

    assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "connect_maintenance"), :count) ==
             1
  end

  test "missing Person pending attempt is removed, legacy org/user grants and live attempts retained" do
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Missing"}))

    {:ok, c} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "api_key"
      })

    for type <- ["org", "user"] do
      assert {:ok, _} =
               Connect.issue_grant(%{
                 credential_id: c.id,
                 resource_type: "mcp",
                 resource_id: "1",
                 owner_type: type,
                 owner_id: person.id,
                 api_key: "legacy"
               })
    end

    now = DateTime.utc_now()
    pending = attempt(now, 600)

    pending =
      pending
      |> OAuthAttempt.changeset(%{
        owner_type: "person",
        owner_id: person.id,
        credential_id: c.id,
        candidate_config: nil
      })
      |> Repo.update!()

    Repo.delete!(person)
    assert {:ok, %{grants_deleted: 0, attempts_deleted: 1}} = PersonLifecycle.reconcile(now: now)
    refute Repo.get(OAuthAttempt, pending.id)
    assert Repo.aggregate(Grant, :count) == 2
  end

  def capture(_, measurements, metadata, pid), do: send(pid, {:cleanup, measurements, metadata})

  defp attempt(now, seconds, extra \\ []) do
    {:ok, encrypted} = SecretConfig.encrypt("encrypted-candidate")

    attrs = %{
      id: Ecto.UUID.generate(),
      owner_type: "org",
      provider: "example",
      config_fingerprint: <<1>>,
      redirect_uri: "https://example.com/callback",
      candidate_config: encrypted,
      pkce_verifier: encrypted,
      expires_at: DateTime.add(now, seconds)
    }

    Repo.insert!(OAuthAttempt.changeset(%OAuthAttempt{}, Map.merge(attrs, Map.new(extra))))
  end
end
