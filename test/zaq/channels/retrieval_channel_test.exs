defmodule Zaq.Channels.RetrievalChannelTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  test "changeset/2 validates required fields" do
    changeset = RetrievalChannel.changeset(%RetrievalChannel{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).channel_config_id
    assert "can't be blank" in errors_on(changeset).channel_id
    assert "can't be blank" in errors_on(changeset).channel_name
    assert "can't be blank" in errors_on(changeset).team_id
    assert "can't be blank" in errors_on(changeset).team_name
  end

  test "changeset/2 enforces uniqueness per config and channel_id" do
    config = insert_channel_config(%{provider: "mattermost"})

    insert_retrieval_channel(config.id, %{
      channel_id: "channel-1",
      channel_name: "Engineering",
      team_id: "team-1",
      team_name: "Team"
    })

    changeset =
      %RetrievalChannel{}
      |> RetrievalChannel.changeset(%{
        channel_config_id: config.id,
        channel_id: "channel-1",
        channel_name: "Engineering",
        team_id: "team-1",
        team_name: "Team",
        active: true
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert "this channel is already configured" in errors_on(changeset).channel_config_id
  end

  test "changeset/2 persists configured_agent_id when assigned" do
    config = insert_channel_config(%{provider: "mattermost"})
    agent = insert_configured_agent()

    inserted =
      %RetrievalChannel{}
      |> RetrievalChannel.changeset(%{
        channel_config_id: config.id,
        channel_id: "channel-assigned",
        channel_name: "Assigned",
        team_id: "team-1",
        team_name: "Team",
        active: true,
        configured_agent_id: agent.id
      })
      |> Repo.insert!()

    assert Map.get(inserted, :configured_agent_id) == agent.id
  end

  test "changeset/2 enforces configured_agent_id foreign key" do
    config = insert_channel_config(%{provider: "mattermost"})

    changeset =
      %RetrievalChannel{}
      |> RetrievalChannel.changeset(%{
        channel_config_id: config.id,
        channel_id: "channel-invalid-agent",
        channel_name: "Invalid",
        team_id: "team-1",
        team_name: "Team",
        active: true,
        configured_agent_id: -1
      })

    assert {:error, failed_changeset} = Repo.insert(changeset)
    assert "does not exist" in errors_on(failed_changeset).configured_agent_id
  end

  test "list_active_by_config/1 returns only active channels" do
    config = insert_channel_config(%{provider: "mattermost"})

    active =
      insert_retrieval_channel(config.id, %{
        channel_id: "channel-active",
        channel_name: "Active",
        team_id: "team-1",
        team_name: "Team",
        active: true
      })

    _inactive =
      insert_retrieval_channel(config.id, %{
        channel_id: "channel-inactive",
        channel_name: "Inactive",
        team_id: "team-1",
        team_name: "Team",
        active: false
      })

    assert [%RetrievalChannel{id: id}] = RetrievalChannel.list_active_by_config(config.id)
    assert id == active.id
  end

  test "active_channel_ids/1 filters by provider, active flag, and config enabled flag" do
    mattermost = insert_channel_config(%{provider: "mattermost", enabled: true})
    teams = insert_channel_config(%{provider: "teams", enabled: true})

    insert_retrieval_channel(mattermost.id, %{
      channel_id: "mm-active",
      channel_name: "Mattermost Active",
      team_id: "team-1",
      team_name: "Team",
      active: true
    })

    insert_retrieval_channel(mattermost.id, %{
      channel_id: "mm-inactive",
      channel_name: "Mattermost Inactive",
      team_id: "team-1",
      team_name: "Team",
      active: false
    })

    insert_retrieval_channel(teams.id, %{
      channel_id: "teams-channel",
      channel_name: "Wrong Provider",
      team_id: "team-2",
      team_name: "Team",
      active: true
    })

    assert ["mm-active"] = RetrievalChannel.active_channel_ids("mattermost")

    mattermost
    |> Ecto.Changeset.change(enabled: false)
    |> Repo.update!()

    assert [] == RetrievalChannel.active_channel_ids("mattermost")
  end

  test "list_by_config/1 returns all channels ordered by channel_name" do
    config = insert_channel_config(%{provider: "mattermost"})

    insert_retrieval_channel(config.id, %{
      channel_id: "z",
      channel_name: "Zulu",
      team_id: "team-1",
      team_name: "Team"
    })

    insert_retrieval_channel(config.id, %{
      channel_id: "a",
      channel_name: "Alpha",
      team_id: "team-1",
      team_name: "Team"
    })

    channels = RetrievalChannel.list_by_config(config.id)
    assert Enum.map(channels, & &1.channel_name) == ["Alpha", "Zulu"]
  end

  test "get_by_config_and_channel/2 finds configured channel" do
    config = insert_channel_config(%{provider: "mattermost"})

    inserted =
      insert_retrieval_channel(config.id, %{
        channel_id: "channel-42",
        channel_name: "Support",
        team_id: "team-1",
        team_name: "Team"
      })

    inserted_id = inserted.id

    assert %RetrievalChannel{id: ^inserted_id} =
             RetrievalChannel.get_by_config_and_channel(config.id, "channel-42")
  end

  defp insert_channel_config(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Config #{unique}",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://mattermost.example.com",
      token: "token-#{unique}",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_retrieval_channel(config_id, attrs) do
    defaults = %{channel_config_id: config_id, active: true}

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_configured_agent do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Routing Agent #{System.unique_integer([:positive, :monotonic])}",
        description: "",
        job: "Route retrieval traffic",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    agent
  end
end
