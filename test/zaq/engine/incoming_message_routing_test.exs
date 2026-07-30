defmodule Zaq.Engine.IncomingMessageRoutingTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
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

    test "non-string topic IDs are rejected instead of silently dropped" do
      config = insert_channel_config!()

      changeset =
        IncomingMessageRouting.change_rule(%IncomingMessageRoutingRule{}, %{
          routing_mode: :none,
          channel_config_id: config.id,
          topic_id: 123
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).topic_id
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
    test "uses transient incoming configured agent before persisted rules" do
      config = insert_channel_config!()
      provider_agent = insert_agent!()
      incoming_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      incoming =
        incoming(
          channel_config_id: config.id,
          attributes: %{"configured_agent_id" => Integer.to_string(incoming_agent.id)}
        )

      assert %{
               mode: :agent,
               source: :incoming,
               rule: nil,
               configured_agent_id: configured_agent_id
             } = IncomingMessageRouting.resolve(incoming)

      assert configured_agent_id == incoming_agent.id
    end

    test "ignores invalid transient incoming configured agent and falls through" do
      config = insert_channel_config!()
      invalid_agent = insert_agent!(conversation_enabled: false)
      provider_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      incoming =
        incoming(
          channel_config_id: config.id,
          attributes: %{"configured_agent_id" => invalid_agent.id}
        )

      assert %{source: :provider, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(incoming)

      assert configured_agent_id == provider_agent.id
    end

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

    test "person-scoped rules expose person-aware source labels" do
      person = insert_person!()
      config = insert_channel_config!()
      retrieval = insert_retrieval_channel!(config)
      agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{person_id: person.id}, %{
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      assert %{source: :person_global} =
               IncomingMessageRouting.resolve(incoming(person: %{id: person.id}))

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{person_id: person.id, channel_config_id: config.id},
          %{
            routing_mode: :agent,
            configured_agent_id: agent.id
          }
        )

      assert %{source: :person_provider} =
               IncomingMessageRouting.resolve(
                 incoming(person: %{id: person.id}, channel_config_id: config.id)
               )

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{person_id: person.id, channel_config_id: config.id, topic_id: "INBOX"},
          %{routing_mode: :agent, configured_agent_id: agent.id}
        )

      assert %{source: :person_topic} =
               IncomingMessageRouting.resolve(
                 incoming(
                   person: %{id: person.id},
                   channel_config_id: config.id,
                   topic_id: "INBOX"
                 )
               )

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{
            person_id: person.id,
            channel_config_id: config.id,
            retrieval_channel_id: retrieval.id
          },
          %{routing_mode: :agent, configured_agent_id: agent.id}
        )

      assert %{source: :person_channel} =
               IncomingMessageRouting.resolve(
                 incoming(
                   person: %{id: person.id},
                   channel_config_id: config.id,
                   retrieval_channel_id: retrieval.id
                 )
               )
    end

    test "ignores non-map transient routing attributes" do
      config = insert_channel_config!()
      provider_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      incoming =
        incoming(channel_config_id: config.id)
        |> Map.update!(:routing_context, &%{&1 | attributes: :not_a_map})

      assert %{source: :provider, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(incoming)

      assert configured_agent_id == provider_agent.id
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

    test "ignores malformed transient configured agent strings" do
      config = insert_channel_config!()
      provider_agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
          routing_mode: :agent,
          configured_agent_id: provider_agent.id
        })

      incoming =
        incoming(
          channel_config_id: config.id,
          attributes: %{"configured_agent_id" => "not-an-id"}
        )

      assert %{source: :provider, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(incoming)

      assert configured_agent_id == provider_agent.id
    end

    test "falls back to default ZAQ agent when no rule matches" do
      assert %{mode: :agent, source: :default_zaq_agent, rule: nil, configured_agent_id: nil} =
               IncomingMessageRouting.resolve(incoming())
    end
  end

  describe "apply_rule_commands/2" do
    test "creates an agent routing rule through existing upsert validation" do
      agent = insert_agent!()

      assert {:ok, %{count: 1, results: [%{status: "upserted", rule: rule}]}} =
               IncomingMessageRouting.apply_rule_commands([
                 %{routing_mode: :agent, configured_agent_id: agent.id}
               ])

      assert rule.routing_mode == "agent"
      assert rule.configured_agent_id == agent.id

      assert %{routing_mode: :agent, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.get_rule(%{})

      assert configured_agent_id == agent.id
    end

    test "blank topic command values are ignored when building scope" do
      config = insert_channel_config!()

      assert {:ok, %{count: 1, results: [%{status: "upserted", rule: rule}]}} =
               IncomingMessageRouting.apply_rule_commands([
                 %{channel_config_id: config.id, topic_id: "   ", routing_mode: :none}
               ])

      assert rule.topic_id == nil
      assert rule.channel_config_id == config.id

      assert %{routing_mode: :none, topic_id: nil} =
               IncomingMessageRouting.get_rule(%{channel_config_id: config.id})
    end

    test "formats none-routing command changeset errors" do
      assert {:error, %{channel_config_id: ["is required for channel rules"]}} =
               IncomingMessageRouting.apply_rule_commands([
                 %{retrieval_channel_id: 123, routing_mode: :none}
               ])
    end

    test "updates rules in batch and clears omitted mailbox selections" do
      config = insert_channel_config!()
      channel = insert_retrieval_channel!(config)
      agent = insert_agent!()

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{channel_config_id: config.id, topic_id: "Archive"},
          %{routing_mode: :agent, configured_agent_id: agent.id}
        )

      assert {:ok, %{count: 3, results: results}} =
               IncomingMessageRouting.apply_rule_commands([
                 %{
                   channel_config_id: config.id,
                   retrieval_channel_id: channel.id,
                   routing_mode: :none
                 },
                 %{
                   channel_config_id: config.id,
                   topic_id: "INBOX",
                   routing_mode: :agent,
                   configured_agent_id: agent.id
                 },
                 %{channel_config_id: config.id, topic_id: "Archive", routing_mode: :clear}
               ])

      assert Enum.map(results, & &1.status) == ["upserted", "upserted", "deleted"]

      assert %{routing_mode: :none} =
               IncomingMessageRouting.get_rule(%{
                 channel_config_id: config.id,
                 retrieval_channel_id: channel.id
               })

      assert %{routing_mode: :agent, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.get_rule(%{channel_config_id: config.id, topic_id: "INBOX"})

      assert configured_agent_id == agent.id

      assert is_nil(
               IncomingMessageRouting.get_rule(%{
                 channel_config_id: config.id,
                 topic_id: "Archive"
               })
             )
    end

    test "returns noop when clearing an absent rule" do
      assert {:ok, %{count: 1, results: [%{status: "noop", rule: nil}]}} =
               IncomingMessageRouting.apply_rule_commands([%{routing_mode: :clear}])
    end

    test "rejects invalid commands" do
      assert {:error, "rules must be a list"} = IncomingMessageRouting.apply_rule_commands(%{})

      assert {:error, "each rule must be a map"} =
               IncomingMessageRouting.apply_rule_commands([:bad])

      assert {:error, "invalid routing_mode \"bad\""} =
               IncomingMessageRouting.apply_rule_commands([%{routing_mode: "bad"}])

      assert {:error, "configured_agent_id is required for agent routing"} =
               IncomingMessageRouting.apply_rule_commands([%{routing_mode: :agent}])
    end

    test "formats changeset errors safely unless raw errors are requested" do
      agent = insert_agent!(conversation_enabled: false)
      command = [%{routing_mode: :agent, configured_agent_id: agent.id}]

      assert {:error, %{configured_agent_id: ["must be conversation-enabled"]}} =
               IncomingMessageRouting.apply_rule_commands(command)

      assert {:error, %Ecto.Changeset{}} =
               IncomingMessageRouting.apply_rule_commands(command, raw_errors: true)
    end
  end

  defp incoming(attrs \\ []) do
    attrs = Map.new(attrs)

    Incoming.new(%{
      content: "hello",
      channel_id: "ch1",
      provider: :email,
      person: Map.get(attrs, :person),
      routing_context: Map.drop(attrs, [:person])
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

  defp insert_person! do
    Repo.insert!(%Person{
      full_name: "Routing Person #{System.unique_integer([:positive, :monotonic])}",
      status: "active"
    })
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
