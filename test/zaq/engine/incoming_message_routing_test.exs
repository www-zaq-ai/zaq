defmodule Zaq.Engine.IncomingMessageRoutingTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, Person}
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.{IncomingMessageRouting, IncomingMessageRoutingRule}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.SystemConfigFixtures

  for policy <- [:inactive_agent, :non_conversation_agent, :channel_config_mismatch] do
    test "#{policy} is rejected by read-only change_rule and merge before any write" do
      survivor = insert_person!()
      loser = insert_person!()
      attrs = invalid_policy(unquote(policy))

      rule =
        Repo.insert!(struct(IncomingMessageRoutingRule, Map.put(attrs, :person_id, loser.id)))

      {:ok, channel} =
        People.add_channel(%{
          person_id: loser.id,
          platform: "slack",
          channel_identifier: "move-#{loser.id}"
        })

      {:ok, grant} =
        Zaq.Permissions.grant({"person", loser.id}, %{
          person_id: loser.id,
          access_rights: ["read"]
        })

      capture_policy_queries()

      changeset = IncomingMessageRouting.change_rule(rule, %{person_id: survivor.id})
      refute_received {:policy_write, _}

      assert {:error, merge_error} = People.merge_persons(survivor, loser)
      assert_policy_error(merge_error, unquote(policy))
      refute_received {:policy_write, _}
      refute changeset.valid?
      assert_policy_error(changeset, unquote(policy))
      assert People.get_channel(channel.id) == channel
      assert Repo.get!(Zaq.Permissions.ResourcePermission, grant.id) == grant
      assert Repo.get!(Person, loser.id) == loser
    end

    test "discarded #{policy} does not invalidate a valid winning final rule" do
      survivor = insert_person!()
      loser = insert_person!()
      attrs = invalid_policy(unquote(policy))

      discarded =
        Repo.insert!(struct(IncomingMessageRoutingRule, Map.put(attrs, :person_id, loser.id)))

      scope = Map.take(attrs, [:channel_config_id, :retrieval_channel_id])

      scope =
        if scope == %{},
          do: scope,
          else:
            Map.put(
              scope,
              :channel_config_id,
              Repo.get!(RetrievalChannel, Map.fetch!(attrs, :retrieval_channel_id)).channel_config_id
            )

      {:ok, winner} =
        IncomingMessageRouting.upsert_rule(Map.put(scope, :person_id, survivor.id), %{
          routing_mode: :none
        })

      assert {:ok, _} = People.merge_persons(survivor, loser)
      assert Repo.get!(IncomingMessageRoutingRule, winner.id) == winner
      refute Repo.get(IncomingMessageRoutingRule, discarded.id)
    end
  end

  for changed_policy <- [:active, :conversation_enabled, :channel_config_id] do
    test "persistence rechecks #{changed_policy} after successful read-only validation" do
      config = insert_channel_config!()
      other = insert_channel_config!(%{provider: "slack"})
      retrieval = insert_retrieval_channel!(config)
      agent = insert_agent!()
      rule = Ecto.put_meta(%IncomingMessageRoutingRule{}, prefix: "public")

      changeset =
        IncomingMessageRouting.change_rule(rule, %{
          routing_mode: :agent,
          configured_agent_id: agent.id,
          channel_config_id: config.id,
          retrieval_channel_id: retrieval.id
        })

      assert changeset.valid?

      if unquote(changed_policy) == :channel_config_id do
        retrieval |> Ecto.Changeset.change(channel_config_id: other.id) |> Repo.update!()
      else
        agent |> Ecto.Changeset.change(%{unquote(changed_policy) => false}) |> Repo.update!()
      end

      assert {:error, error} = Repo.insert(changeset)

      assert_policy_error(
        error,
        if(unquote(changed_policy) == :channel_config_id,
          do: :channel_config_mismatch,
          else: :inactive_agent
        )
      )
    end
  end

  test "read-only policy queries use loaded prefix and persistence honors explicit prefix" do
    config = insert_channel_config!()
    retrieval = insert_retrieval_channel!(config)
    agent = insert_agent!()
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and String.starts_with?(metadata.query, "SELECT"),
          do: send(owner, {:policy_read, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    rule = Ecto.put_meta(%IncomingMessageRoutingRule{}, prefix: "public")

    changeset =
      IncomingMessageRouting.change_rule(rule, %{
        routing_mode: :agent,
        configured_agent_id: agent.id,
        channel_config_id: config.id,
        retrieval_channel_id: retrieval.id
      })

    assert changeset.valid?
    assert_received {:policy_read, agent_query}
    assert agent_query =~ ~s("public"."configured_agents")
    assert_received {:policy_read, channel_query}
    assert channel_query =~ ~s("public"."retrieval_channels")

    # Explicit Repo options override schema metadata for both the write and
    # prepared policy reads. No alternate schema or application process needed.
    changeset = %{changeset | data: Ecto.put_meta(changeset.data, prefix: "unused_policy_prefix")}
    assert {:ok, stored} = Repo.insert(changeset, prefix: "public")
    assert stored.configured_agent_id == agent.id
    assert_received {:policy_read, agent_query}
    assert agent_query =~ ~s("public"."configured_agents")
    assert_received {:policy_read, channel_query}
    assert channel_query =~ ~s("public"."retrieval_channels")
  end

  defp invalid_policy(:channel_config_mismatch) do
    config = insert_channel_config!()
    other = insert_channel_config!(%{provider: "slack"})
    retrieval = insert_retrieval_channel!(config)
    %{routing_mode: :none, channel_config_id: other.id, retrieval_channel_id: retrieval.id}
  end

  defp invalid_policy(policy) do
    agent =
      insert_agent!(
        if(policy == :inactive_agent, do: [active: false], else: [conversation_enabled: false])
      )

    %{routing_mode: :agent, configured_agent_id: agent.id}
  end

  defp assert_policy_error(changeset, :channel_config_mismatch),
    do: assert(errors_on(changeset).retrieval_channel_id == ["must belong to channel config"])

  defp assert_policy_error(changeset, _policy),
    do: assert(errors_on(changeset).configured_agent_id == ["must be conversation-enabled"])

  defp capture_policy_queries do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and Regex.match?(~r/^(INSERT|UPDATE|DELETE) /, metadata.query),
          do: send(owner, {:policy_write, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

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
    test "inserts a new struct and moves a loaded rule without replacing its grant reference" do
      old_person = Repo.insert!(%Person{full_name: "Old"})
      new_person = Repo.insert!(%Person{full_name: "New"})

      assert {:ok, rule} =
               IncomingMessageRouting.upsert_rule(%IncomingMessageRoutingRule{}, %{
                 person_id: old_person.id,
                 routing_mode: :none
               })

      resource = {"incoming_message_routing_rule", to_string(rule.id)}

      {:ok, grant} =
        Zaq.Permissions.grant(resource, %{person_id: new_person.id, access_rights: ["read"]})

      assert {:ok, updated} =
               IncomingMessageRouting.upsert_rule(
                 Repo.get!(IncomingMessageRoutingRule, rule.id),
                 %{
                   person_id: new_person.id
                 }
               )

      assert updated.id == rule.id
      assert updated.person_id == new_person.id
      assert IncomingMessageRouting.get_rule(%{person_id: old_person.id}) == nil
      assert IncomingMessageRouting.get_rule(%{person_id: new_person.id}) == updated
      assert Zaq.Permissions.list(resource) == [Repo.preload(grant, [:person, :team])]
    end

    test "invalid loaded update leaves the original rule unchanged" do
      {:ok, rule} = IncomingMessageRouting.upsert_rule(%{}, %{routing_mode: :none})

      assert {:error, changeset} =
               IncomingMessageRouting.upsert_rule(rule, %{routing_mode: :agent})

      assert errors_on(changeset).configured_agent_id == ["can't be blank"]
      assert Repo.get!(IncomingMessageRoutingRule, rule.id) == rule
    end

    test "conflicting loaded scope returns a changeset and rolls back earlier writes" do
      first = Repo.insert!(%Person{full_name: "First"})
      second = Repo.insert!(%Person{full_name: "Second"})

      {:ok, rule} =
        IncomingMessageRouting.upsert_rule(%{person_id: first.id}, %{routing_mode: :none})

      {:ok, occupied} =
        IncomingMessageRouting.upsert_rule(%{person_id: second.id}, %{routing_mode: :none})

      assert {:error, changeset} =
               Repo.transaction(fn ->
                 first |> Ecto.Changeset.change(full_name: "Changed") |> Repo.update!()

                 case IncomingMessageRouting.upsert_rule(rule, %{person_id: second.id}) do
                   {:error, changeset} -> Repo.rollback(changeset)
                   {:ok, updated} -> updated
                 end
               end)

      assert errors_on(changeset).person_id == ["has already been taken"]
      assert Repo.get!(Person, first.id).full_name == "First"
      assert Repo.get!(IncomingMessageRoutingRule, rule.id) == rule
      assert Repo.get!(IncomingMessageRoutingRule, occupied.id) == occupied
    end

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
