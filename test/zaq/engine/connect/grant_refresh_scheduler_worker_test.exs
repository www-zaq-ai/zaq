defmodule Zaq.Engine.Connect.GrantRefreshSchedulerWorkerTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.GrantRefreshSchedulerWorker
  alias Zaq.Engine.Connect.GrantRefreshWorker

  defp oauth_credential! do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "oauth-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "client-id",
        client_secret: "client-secret",
        scopes: ["scope.read"]
      })

    credential
  end

  defp issue_oauth_grant!(credential, attrs) do
    config_id = data_source_config_id_for(credential.provider)

    base = %{
      credential_id: credential.id,
      resource_type: "data_source",
      resource_id: Integer.to_string(config_id),
      owner_type: "org",
      owner_id: nil,
      request_format: "bearer",
      metadata: %{},
      access_token: "access",
      refresh_token: "refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    {:ok, grant} = Connect.issue_grant(Map.merge(base, attrs))
    grant
  end

  defp data_source_config_id_for(provider) do
    case Repo.get_by(ChannelConfig, provider: provider, kind: "data_source") do
      %ChannelConfig{id: id} ->
        id

      nil ->
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          "name" => "cfg-#{provider}-#{System.unique_integer([:positive])}",
          "provider" => provider,
          "kind" => "data_source",
          "enabled" => true,
          "settings" => %{}
        })
        |> Repo.insert!()
        |> Map.fetch!(:id)
    end
  end

  test "perform/1 returns :ok and schedules refresh jobs for expiring oauth grants" do
    credential = oauth_credential!()
    soon = DateTime.add(DateTime.utc_now(), 120, :second)

    grant_1 = issue_oauth_grant!(credential, %{expires_at: soon})
    grant_2 = issue_oauth_grant!(credential, %{expires_at: soon})

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = GrantRefreshSchedulerWorker.perform(%Oban.Job{})

      enqueued = all_enqueued(worker: GrantRefreshWorker)
      grant_ids = Enum.map(enqueued, & &1.args["grant_id"])

      assert length(enqueued) == 2
      assert grant_1.id in grant_ids
      assert grant_2.id in grant_ids
    end)
  end

  test "perform/1 skips non-expiring and non-oauth grants" do
    credential = oauth_credential!()
    far_future = DateTime.add(DateTime.utc_now(), 7200, :second)

    _ignored_future = issue_oauth_grant!(credential, %{expires_at: far_future})

    {:ok, api_key_credential} =
      Connect.create_credential(%{
        name: "api-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "static-key"
      })

    {:ok, _api_grant} =
      Connect.issue_grant(%{
        credential_id: api_key_credential.id,
        resource_type: "mcp",
        resource_id: "api-1",
        owner_type: "org",
        owner_id: nil,
        request_format: "raw",
        metadata: %{},
        api_key: "shared"
      })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = GrantRefreshSchedulerWorker.perform(%Oban.Job{})
      assert all_enqueued(worker: GrantRefreshWorker) == []
    end)
  end
end
