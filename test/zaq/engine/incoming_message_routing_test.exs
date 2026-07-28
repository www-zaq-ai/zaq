defmodule Zaq.Engine.IncomingMessageRoutingTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.{IncomingMessageRouting, IncomingMessageRoutingRule}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.SystemConfigFixtures

  describe "changeset/2" do
    test "requires configured agent for agent mode" do
      changeset =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{routing_mode: :agent})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).configured_agent_id
    end

    test "clears configured agent for none mode" do
      changeset =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          configured_agent_id: 123
        })

      assert changeset.valid?
      assert get_change(changeset, :configured_agent_id) == nil
    end

    test "requires channel config for topic and retrieval-channel rules" do
      topic =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          topic_id: "INBOX"
        })

      channel =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          retrieval_channel_id: 1
        })

      assert "is required for topic rules" in errors_on(topic).channel_config_id
      assert "is required for channel rules" in errors_on(channel).channel_config_id
    end

    test "blank topic IDs normalize to nil" do
      config = insert_channel_config!()

      changeset =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          channel_config_id: config.id,
          topic_id: "   "
        })

      assert changeset.valid?
      assert get_field(changeset, :topic_id) == nil
    end

    test "explicit nil topic IDs normalize through non-binary branch" do
      rule = %IncomingMessageRoutingRule{topic_id: "INBOX"}

      changeset =
        IncomingMessageRouting.change_rule(rule, %{
          routing_mode: :none,
          topic_id: nil
        })

      assert changeset.valid?
      assert get_field(changeset, :topic_id) == nil
    end

    test "missing routing mode leaves destination validation unchanged" do
      changeset = IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).routing_mode
      refute Map.has_key?(errors_on(changeset), :configured_agent_id)
    end

    test "retrieval-channel scoped rules reject topic IDs" do
      changeset =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          channel_config_id: 1,
          retrieval_channel_id: 2,
          topic_id: "INBOX"
        })

      refute changeset.valid?
      assert "cannot be set for retrieval channel rules" in errors_on(changeset).topic_id
    end
  end

  describe "upsert_rule/2" do
    test "creates and updates exact scope rules" do
      agent = insert_agent!()

      assert {:ok, rule} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: :agent,
                 configured_agent_id: agent.id
               })

      assert rule.configured_agent_id == agent.id

      assert {:ok, updated} = IncomingMessageRouting.upsert_rule(%{}, %{routing_mode: :none})
      assert updated.id == rule.id
      assert updated.routing_mode == :none
      assert updated.configured_agent_id == nil
    end

    test "rejects non conversation-enabled agents" do
      agent = insert_agent!(conversation_enabled: false)

      assert {:error, changeset} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: :agent,
                 configured_agent_id: agent.id
               })

      assert "must be conversation-enabled" in errors_on(changeset).configured_agent_id
    end

    test "supports email mailbox topic rules" do
      config = insert_channel_config!()
      agent = insert_agent!()

      assert {:ok, rule} =
               IncomingMessageRouting.upsert_rule(
                 %{channel_config_id: config.id, topic_id: " INBOX "},
                 %{routing_mode: :agent, configured_agent_id: agent.id}
               )

      assert rule.topic_id == "INBOX"
      assert rule.channel_config_id == config.id
    end

    test "retrieval channel must belong to the selected channel config" do
      config_a = insert_channel_config!()
      config_b = insert_channel_config!(%{provider: "slack"})
      retrieval = insert_retrieval_channel!(config_a)

      assert {:error, changeset} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: :none,
                 channel_config_id: config_b.id,
                 retrieval_channel_id: retrieval.id
               })

      assert "must belong to channel config" in errors_on(changeset).retrieval_channel_id
    end

    test "retrieval channel scoped rule accepts matching channel config" do
      config = insert_channel_config!()
      retrieval = insert_retrieval_channel!(config)

      assert {:ok, rule} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: :none,
                 channel_config_id: config.id,
                 retrieval_channel_id: retrieval.id
               })

      assert rule.channel_config_id == config.id
      assert rule.retrieval_channel_id == retrieval.id
      assert rule.routing_mode == :none
    end
  end

  describe "resolve/2" do
    test "uses topic before provider and global rules" do
      config = insert_channel_config!()
      global_agent = insert_agent!()
      provider_agent = insert_agent!()
      topic_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{}, %{
          routing_mode: :agent,
          configured_agent_id: global_agent.id
        })

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      {:ok, topic_rule} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id, topic_id: "INBOX"}, %{
          routing_mode: :agent,
          configured_agent_id: topic_agent.id
        })

      incoming = incoming(channel_config_id: config.id, topic_id: "INBOX")

      assert %{
               mode: :agent,
               source: :topic,
               rule: %{id: rule_id},
               configured_agent_id: configured_agent_id
             } = IncomingMessageRouting.resolve(incoming)

      assert rule_id == topic_rule.id
      assert configured_agent_id == topic_agent.id
    end

    test "none is terminal" do
      config = insert_channel_config!()
      provider_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      {:ok, topic_rule} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id, topic_id: "INBOX"}, %{
          routing_mode: :none
        })

      assert %{mode: :none, source: :topic, rule: %{id: rule_id}} =
               IncomingMessageRouting.resolve(
                 incoming(channel_config_id: config.id, topic_id: "INBOX")
               )

      assert rule_id == topic_rule.id
    end

    test "invalid agent rule falls through" do
      config = insert_channel_config!()
      invalid_agent = insert_agent!(conversation_enabled: false)
      provider_agent = insert_agent!()

      Repo.insert!(%IncomingMessageRoutingRule{
        channel_config_id: config.id,
        topic_id: "INBOX",
        routing_mode: :agent,
        configured_agent_id: invalid_agent.id
      })

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      assert %{source: :provider, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(
                 incoming(channel_config_id: config.id, topic_id: "INBOX")
               )

      assert configured_agent_id == provider_agent.id
    end

    test "falls back to default ZAQ agent when no rule matches" do
      assert %{mode: :agent, source: :default_zaq_agent, rule: nil, configured_agent_id: nil} =
               IncomingMessageRouting.resolve(incoming())
    end
  end

  defp incoming(attrs \\ []) do
    Incoming.new(%{
      content: "hello",
      channel_id: "ch1",
      provider: :email,
      routing_context: Map.new(attrs)
    })
  end

  defp insert_channel_config!(attrs \\ %{}) do
    defaults = %{
      name: "Email #{System.unique_integer([:positive, :monotonic])}",
      provider: "mattermost",
      url: "imap.example.com",
      token: "token",
      enabled: true,
      kind: "retrieval",
      settings: %{}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_retrieval_channel!(config, attrs \\ %{}) do
    defaults = %{
      channel_config_id: config.id,
      channel_id: "channel-#{System.unique_integer([:positive, :monotonic])}",
      channel_name: "General",
      team_id: "team-1",
      team_name: "Team",
      active: true
    }

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_agent!(attrs \\ []) do
    credential = SystemConfigFixtures.ai_credential_fixture()

    defaults = %{
      name: "Routing Agent #{System.unique_integer([:positive, :monotonic])}",
      description: "",
      job: "Route incoming messages",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: true,
      active: true,
      advanced_options: %{}
    }

    changes = Enum.into(attrs, %{})

    %ConfiguredAgent{}
    |> ConfiguredAgent.changeset(Map.merge(defaults, changes))
    |> Repo.insert!()
  end
end
