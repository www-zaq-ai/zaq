defmodule Zaq.Engine.Connect.GrantRefreshWorkerTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  defmodule StubOAuthMissingRefreshToken do
    def oauth_refresh_token(_config, _params) do
      {:ok,
       %{
         access_token: "new-access",
         refresh_token: nil,
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
         scopes: ["scope.from.refresh"]
       }}
    end
  end

  alias Oban.Job
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, GrantRefreshWorker}
  alias Zaq.Repo
  alias Zaq.Test.StubNoOAuthRefresh
  alias Zaq.Test.StubOAuthSuccess

  defp insert_config(provider, attrs) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "data_source",
      url: "https://#{provider}.example.com",
      token: "tok-#{unique}",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, Map.new(attrs)))
    |> Repo.insert!()
  end

  # `Connect.issue_grant/1` rejects a data_source grant whose channel config names another
  # provider, so a test that wants the "no config" path needs an id no row holds. Migrations
  # seed channel_configs rows, so that id cannot be a literal.
  defp unused_config_id do
    to_string((Repo.aggregate(ChannelConfig, :max, :id) || 0) + 1)
  end

  defp insert_leased_grant(deadline) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "Leased OAuth credential #{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "leased-#{System.unique_integer([:positive])}",
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    Repo.update!(
      Ecto.Changeset.change(grant,
        refresh_claim: Ecto.UUID.generate(),
        refresh_claim_until: deadline
      )
    )
  end

  test "perform/1 returns ok when grant does not exist" do
    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => -1}})
  end

  test "perform/1 returns ok for non oauth2 or non active grants" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "API credential",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "shared"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "1",
        owner_type: "org",
        metadata: %{},
        status: "active"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns ok for revoked oauth2 grants" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "Revoked OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "revoked-1",
        owner_type: "org",
        metadata: %{},
        status: "revoked",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns refresh error for active oauth2 grant" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: unused_config_id(),
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert {:error, :refresh_failed} =
             GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/2 snoozes until an active refresh lease expires" do
    now = ~U[2026-09-18 18:00:00Z]
    grant = insert_leased_grant(DateTime.add(now, 75))

    assert {:snooze, 75} =
             GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}}, now: now)

    assert Repo.get!(Grant, grant.id).refresh_claim_until == DateTime.add(now, 75)
  end

  test "perform/2 snoozes when the lease is cleared after contention" do
    now = ~U[2026-09-18 18:00:00Z]
    grant = insert_leased_grant(DateTime.add(now, 75))

    clock = fn ->
      if Repo.in_transaction?() do
        now
      else
        Repo.update!(
          Ecto.Changeset.change(Repo.get!(Grant, grant.id),
            refresh_claim: nil,
            refresh_claim_until: nil
          )
        )

        now
      end
    end

    assert {:snooze, 1} =
             GrantRefreshWorker.perform(
               %Job{args: %{"grant_id" => grant.id}},
               now: clock
             )

    reloaded = Repo.get!(Grant, grant.id)
    assert reloaded.refresh_claim == nil
    assert reloaded.refresh_claim_until == nil
    assert reloaded.access_token == "a"
    assert reloaded.refresh_token == "r"
    assert reloaded.status == "active"
  end

  test "perform/2 snoozes when the grant is deleted after contention" do
    now = ~U[2026-09-18 18:00:00Z]
    grant = insert_leased_grant(DateTime.add(now, 75))

    clock = fn ->
      if Repo.in_transaction?() do
        now
      else
        Repo.delete!(Repo.get!(Grant, grant.id))
        now
      end
    end

    assert {:snooze, 1} =
             GrantRefreshWorker.perform(
               %Job{args: %{"grant_id" => grant.id}},
               now: clock
             )

    assert Repo.get(Grant, grant.id) == nil
  end

  test "perform/2 snoozes for a lease reached during handoff" do
    now = ~U[2026-09-18 18:00:00Z]
    deadline = DateTime.add(now, 75)

    for outside_now <- [deadline, DateTime.add(deadline, 1)] do
      grant = insert_leased_grant(deadline)
      clock = fn -> if Repo.in_transaction?(), do: now, else: outside_now end

      assert {:snooze, 1} =
               GrantRefreshWorker.perform(
                 %Job{args: %{"grant_id" => grant.id}},
                 now: clock
               )

      reloaded = Repo.get!(Grant, grant.id)
      assert reloaded.refresh_claim == grant.refresh_claim
      assert reloaded.refresh_claim_until == deadline
      assert reloaded.access_token == "a"
      assert reloaded.refresh_token == "r"
      assert reloaded.status == "active"
    end
  end

  property "perform/2 always returns a positive remaining lease delay" do
    now = ~U[2026-09-18 18:00:00Z]

    check all(remaining_seconds <- integer(1..120), max_runs: 15) do
      deadline = DateTime.add(now, remaining_seconds)
      grant = insert_leased_grant(deadline)
      clock = fn -> now end

      assert {:snooze, ^remaining_seconds} =
               GrantRefreshWorker.perform(
                 %Job{args: %{"grant_id" => grant.id}},
                 now: clock
               )

      reloaded = Repo.get!(Grant, grant.id)
      assert reloaded.refresh_claim_until == deadline
      assert reloaded.refresh_claim == grant.refresh_claim
    end
  end

  test "perform/1 returns ok when oauth2 refresh succeeds" do
    config = insert_config(:google_drive, kind: "data_source")

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubOAuthSuccess}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: to_string(config.id),
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns ok when bridge does not support oauth2 refresh" do
    config = insert_config(:slack, kind: "data_source")

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      slack: %{bridge: StubNoOAuthRefresh}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "slack",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: to_string(config.id),
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 keeps existing refresh_token when refresh payload omits it" do
    config = insert_config(:google_drive, kind: "data_source")

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StubOAuthMissingRefreshToken}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: to_string(config.id),
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "old-access",
        refresh_token: "old-refresh"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})

    refreshed = Repo.get!(Connect.Grant, grant.id)
    assert refreshed.access_token == "new-access"
    assert refreshed.refresh_token == "old-refresh"
    assert refreshed.scopes == ["scope.from.refresh"]
  end
end
