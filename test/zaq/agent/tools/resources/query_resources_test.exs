defmodule Zaq.Agent.Tools.Resources.QueryResourcesTest do
  use Zaq.DataCase, async: true

  alias Jido.Action.Runtime
  alias Jido.Action.Schema
  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Agent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Tools.Resources.QueryResources
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Permissions
  alias Zaq.Repo

  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  describe "schemas" do
    test "uses valid Zoi schemas and exposes a tool schema" do
      assert Schema.schema_type(QueryResources.schema()) == :zoi
      assert Schema.schema_type(QueryResources.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(QueryResources.schema())
      assert :ok = Schema.validate_config_schema(QueryResources.output_schema())

      tool = QueryResources.to_tool()
      assert tool.name == "query_resources"

      assert tool.description =~
               "agent, mcp, skill, user, person, ai_provider, channel_config, incoming_message_routing_rule"
    end

    test "runtime validation preserves query params" do
      assert {:ok, params} =
               Runtime.validate_params(
                 %{
                   "mode" => "query",
                   "resource_type" => "agent",
                   "query" => "Support",
                   "fields" => ["id", "name"],
                   "filters" => %{"active" => true},
                   "limit" => 5
                 },
                 QueryResources
               )

      assert params.mode == "query"
      assert params.resource_type == "agent"
      assert params.fields == ["id", "name"]
      assert params.filters == %{"active" => true}
    end
  end

  describe "describe mode" do
    test "lists all resource types without dumping resource records" do
      assert {:ok, result} = QueryResources.run(%{mode: "describe"}, %{})

      resource_types = Enum.map(result.descriptions, & &1.resource_type)

      assert resource_types ==
               ~w(agent mcp skill user person ai_provider channel_config incoming_message_routing_rule)

      assert result.resources == []
      assert result.resource == nil
    end

    test "describes a single resource type" do
      assert {:ok, result} =
               QueryResources.run(%{mode: "describe", resource_type: "skill"}, %{})

      assert [%{resource_type: "skill", fields: fields, search_fields: search_fields}] =
               result.descriptions

      assert "body" not in fields
      assert "body" not in search_fields
      assert "tags" in search_fields
    end

    test "describes channels as a default person field" do
      assert {:ok, result} =
               QueryResources.run(%{mode: "describe", resource_type: "person"}, %{})

      assert [%{fields: fields, search_fields: search_fields}] = result.descriptions
      assert "channels" in fields
      assert "channels" not in search_fields
    end

    test "describes incoming message routing rule fields" do
      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "describe", resource_type: "incoming_message_routing_rule"},
                 %{}
               )

      assert [description] = result.descriptions
      assert description.public == false
      assert "person_id" in description.fields
      assert "channel_config_id" in description.fields
      assert "person_id" in description.search_fields
      assert "channel_config_id" in description.search_fields
      assert "routing_mode" in description.filter_fields
    end

    test "describes channel config with nested retrieval channels" do
      assert {:ok, result} =
               QueryResources.run(%{mode: "describe", resource_type: "channel_config"}, %{})

      assert [description] = result.descriptions
      assert description.public == false
      assert "retrieval_channels" in description.fields
      assert "retrieval_channels" in description.search_fields
      assert "token" not in description.fields
      assert "settings" not in description.fields
    end

    test "describe mode rejects unknown resource types" do
      assert {:error, {:unknown_resource_type, "bogus"}} =
               QueryResources.run(%{mode: "describe", resource_type: "bogus"}, %{})
    end
  end

  describe "public resources" do
    test "lists public agents without an actor" do
      credential = openai_credential_fixture()
      agent = agent_fixture(credential, %{name: "Support Agent", description: "Helps customers"})

      _other =
        agent_fixture(credential, %{name: "Finance Agent", description: "Handles invoices"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   query: "Support",
                   fields: ["id", "name"],
                   limit: 10
                 },
                 %{}
               )

      assert result.total_count == 1
      assert result.resources == [%{id: agent.id, name: "Support Agent"}]
    end

    test "returns a missing public resource as not found" do
      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "agent", id: -1},
                 %{}
               )

      assert result.mode == "get"
      assert result.found == false
      assert result.resource == nil
    end

    test "gets a public MCP endpoint without exposing secret fields" do
      endpoint = mcp_fixture(%{})

      assert {:ok, result} =
               QueryResources.run(%{mode: "query", resource_type: "mcp", id: endpoint.id}, %{})

      assert result.found == true
      assert result.resource.name == endpoint.name
      refute Map.has_key?(result.resource, :secret_headers)
      refute Map.has_key?(result.resource, :headers)
    end

    test "rejects non-allowlisted requested fields" do
      assert {:error, {:unsupported_field, ["body"]}} =
               QueryResources.run(
                 %{mode: "query", resource_type: "skill", fields: ["id", "body"]},
                 %{}
               )
    end
  end

  describe "private resources" do
    test "rejects private resource listing without actor" do
      assert {:error, :unauthorized} =
               QueryResources.run(%{mode: "query", resource_type: "person"}, %{})
    end

    test "rejects private resource get without an actor" do
      target = user_fixture(%{username: "private_user"})

      assert {:error, :unauthorized} =
               QueryResources.run(
                 %{mode: "query", resource_type: "user", id: target.id, fields: ["id"]},
                 %{}
               )
    end

    test "skip_permissions can list private AI providers without api_key" do
      credential = ai_credential_fixture(%{name: "OpenAI Prod", provider: "openai"})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "ai_provider", query: "OpenAI", limit: 5},
                 %{skip_permissions: true}
               )

      assert Enum.any?(result.resources, &(&1.id == credential.id))
      refute Enum.any?(result.resources, &Map.has_key?(&1, :api_key))
    end

    test "skip_permissions authorizes private AI provider get without exposing api_key" do
      credential = ai_credential_fixture(%{name: "OpenAI Get Prod", provider: "openai"})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "ai_provider", id: credential.id},
                 %{skip_permissions: true}
               )

      assert result.found == true
      assert result.resource.id == credential.id
      refute Map.has_key?(result.resource, :api_key)
    end

    test "permission grant allows a person to get a private resource" do
      actor_person = person_fixture(%{full_name: "Actor Person"})
      target = user_fixture(%{username: "private_user"})

      {:ok, _permission} =
        Permissions.grant(target, %{person_id: actor_person.id, access_rights: ["read"]})

      context = %{actor: %{person: %{id: actor_person.id, team_ids: []}}}

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "user",
                   id: target.id,
                   fields: ["id", "username"]
                 },
                 context
               )

      assert result.resource == %{id: target.id, username: "private_user"}
      refute Map.has_key?(result.resource, :password_hash)
    end

    test "private resource get with actor but without grant is unauthorized" do
      actor_person = person_fixture(%{full_name: "Unauthorized Actor"})
      target = user_fixture(%{username: "unauthorized_private_user"})

      assert {:error, :unauthorized} =
               QueryResources.run(
                 %{mode: "query", resource_type: "user", id: target.id, fields: ["id"]},
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )
    end

    test "permission grant filters private list results" do
      actor_person = person_fixture(%{full_name: "List Actor"})
      allowed = person_fixture(%{full_name: "Visible Contact"})
      _hidden = person_fixture(%{full_name: "Hidden Contact"})

      {:ok, _permission} =
        Permissions.grant(allowed, %{person_id: actor_person.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "person",
                   query: "Contact",
                   fields: ["id", "full_name"]
                 },
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )

      assert result.resources == [%{id: allowed.id, full_name: "Visible Contact"}]
    end

    test "person get includes attached channels by default" do
      actor_person = person_fixture(%{full_name: "Channel Actor"})
      target = person_fixture(%{full_name: "Channel Target"})

      channel =
        person_channel_fixture(target, %{
          platform: "mattermost",
          channel_identifier: "U_CHANNEL_TARGET",
          username: "target_user",
          display_name: "Target User",
          metadata: %{"secret_note" => "do not expose"},
          weight: 0
        })

      {:ok, _permission} =
        Permissions.grant(target, %{person_id: actor_person.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "person", id: target.id},
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )

      assert result.resource.id == target.id
      assert Enum.any?(result.resource.channels, &(&1.id == channel.id))

      serialized_channel = Enum.find(result.resource.channels, &(&1.id == channel.id))
      assert serialized_channel.platform == "mattermost"
      assert serialized_channel.channel_identifier == "U_CHANNEL_TARGET"
      assert serialized_channel.username == "target_user"
      refute Map.has_key?(serialized_channel, :metadata)
    end

    test "person list includes attached channels by default" do
      actor_person = person_fixture(%{full_name: "List Channel Actor"})
      allowed = person_fixture(%{full_name: "List Channel Contact"})

      channel =
        person_channel_fixture(allowed, %{platform: "slack", channel_identifier: "U_SLACK"})

      {:ok, _permission} =
        Permissions.grant(allowed, %{person_id: actor_person.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "person", query: "List Channel Contact"},
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )

      assert [%{channels: channels}] = result.resources
      assert Enum.any?(channels, &(&1.id == channel.id and &1.platform == "slack"))
    end

    test "rejects routing rule listing without actor" do
      assert {:error, :unauthorized} =
               QueryResources.run(
                 %{mode: "query", resource_type: "incoming_message_routing_rule"},
                 %{}
               )
    end

    test "skip_permissions can search routing rules by person and channel config ids" do
      person = person_fixture(%{full_name: "Routing Query Person"})
      config = channel_config_fixture(%{})
      agent = agent_fixture(openai_credential_fixture(), %{name: "Routing Query Agent"})

      rule =
        routing_rule_fixture(%{
          person_id: person.id,
          channel_config_id: config.id,
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      assert {:ok, by_person} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "incoming_message_routing_rule",
                   query: to_string(person.id),
                   fields: ["id", "person_id", "channel_config_id"]
                 },
                 %{skip_permissions: true}
               )

      assert Enum.any?(by_person.resources, &(&1.id == rule.id and &1.person_id == person.id))

      assert {:ok, by_channel_config} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "incoming_message_routing_rule",
                   query: to_string(config.id),
                   fields: ["id", "person_id", "channel_config_id"]
                 },
                 %{skip_permissions: true}
               )

      assert Enum.any?(
               by_channel_config.resources,
               &(&1.id == rule.id and &1.channel_config_id == config.id)
             )
    end

    test "permission grant allows querying only granted routing rules" do
      actor_person = person_fixture(%{full_name: "Routing Rule Actor"})
      allowed_person = person_fixture(%{full_name: "Allowed Routing Person"})
      hidden_person = person_fixture(%{full_name: "Hidden Routing Person"})
      config = channel_config_fixture(%{})
      agent = agent_fixture(openai_credential_fixture(), %{name: "Granted Routing Agent"})

      allowed_rule =
        routing_rule_fixture(%{
          person_id: allowed_person.id,
          channel_config_id: config.id,
          topic_id: "INBOX",
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      _hidden_rule =
        routing_rule_fixture(%{
          person_id: hidden_person.id,
          routing_mode: :none
        })

      {:ok, _permission} =
        Permissions.grant(allowed_rule, %{person_id: actor_person.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "incoming_message_routing_rule",
                   filters: %{"channel_config_id" => config.id},
                   fields: ["id", "person_id", "channel_config_id", "topic_id", "routing_mode"]
                 },
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )

      assert result.resources == [
               %{
                 id: allowed_rule.id,
                 person_id: allowed_person.id,
                 channel_config_id: config.id,
                 topic_id: "INBOX",
                 routing_mode: :agent
               }
             ]
    end

    test "skip_permissions can list channel configs with nested retrieval channels" do
      config = channel_config_fixture(%{provider: "mattermost", name: "Mattermost Main"})

      channel =
        retrieval_channel_fixture(config, %{
          channel_id: "town-square-id",
          channel_name: "Town Square",
          team_id: "team-zaq",
          team_name: "ZAQ",
          agent_routing_mode: "agent"
        })

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "channel_config",
                   query: "Town Square"
                 },
                 %{skip_permissions: true}
               )

      assert [%{retrieval_channels: channels} = resource] = result.resources
      assert resource.id == config.id
      assert resource.provider == "mattermost"
      refute Map.has_key?(resource, :token)
      refute Map.has_key?(resource, :settings)

      assert [serialized_channel] = channels
      assert serialized_channel.id == channel.id
      assert serialized_channel.channel_config_id == config.id
      assert serialized_channel.channel_id == "town-square-id"
      assert serialized_channel.channel_name == "Town Square"
      assert serialized_channel.team_name == "ZAQ"
      assert serialized_channel.agent_routing_mode == "agent"
    end

    test "permission grant allows reading a channel config without secrets" do
      actor_person = person_fixture(%{full_name: "Channel Config Actor"})
      config = channel_config_fixture(%{provider: "slack", name: "Slack Main"})
      _channel = retrieval_channel_fixture(config, %{channel_name: "General"})

      {:ok, _permission} =
        Permissions.grant(config, %{person_id: actor_person.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "channel_config", id: config.id},
                 %{actor: %{person: %{id: actor_person.id, team_ids: []}}}
               )

      assert result.resource.id == config.id
      assert result.resource.kind == "retrieval"
      assert [%{channel_name: "General"}] = result.resource.retrieval_channels
      refute Map.has_key?(result.resource, :token)
      refute Map.has_key?(result.resource, :settings)
    end
  end

  describe "validation" do
    test "pre-validation preserves non-map params" do
      assert {:ok, :raw_params} = QueryResources.on_before_validate_params(:raw_params)
      assert {:ok, nil} = QueryResources.on_before_validate_params(nil)
    end

    test "query mode requires a resource type" do
      assert {:error, :resource_type_required} =
               QueryResources.run(%{mode: "query"}, %{})
    end

    test "rejects unknown filters and sort fields" do
      assert {:error, {:unsupported_filter, ["password_hash"]}} =
               QueryResources.run(
                 %{mode: "query", resource_type: "user", filters: %{"password_hash" => "x"}},
                 %{skip_permissions: true}
               )

      assert {:error, {:unsupported_sort, ["password_hash"]}} =
               QueryResources.run(
                 %{mode: "query", resource_type: "user", sort_by: "password_hash"},
                 %{skip_permissions: true}
               )
    end

    test "paginates list results" do
      credential = openai_credential_fixture()
      first = agent_fixture(credential, %{name: "A Agent"})
      second = agent_fixture(credential, %{name: "B Agent"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   fields: ["id", "name"],
                   sort_by: "name",
                   limit: 1,
                   offset: 1
                 },
                 %{}
               )

      assert result.limit == 1
      assert result.offset == 1
      assert result.total_count >= 2

      assert result.resources in [
               [%{id: second.id, name: second.name}],
               [%{id: first.id, name: first.name}]
             ]
    end

    test "rejects non-list requested fields" do
      assert {:error, :unsupported_field} =
               QueryResources.run(
                 %{mode: "query", resource_type: "agent", fields: "id"},
                 %{}
               )
    end

    test "search ignores non-binary query values" do
      credential = openai_credential_fixture()
      first = agent_fixture(credential, %{name: "Alpha Agent"})
      second = agent_fixture(credential, %{name: "Beta Agent"})

      assert {:ok, result} =
               QueryResources.run(
                 %{mode: "query", resource_type: "agent", query: 123, fields: ["id"]},
                 %{}
               )

      returned_ids = Enum.map(result.resources, & &1.id)

      assert result.total_count >= 2
      assert first.id in returned_ids
      assert second.id in returned_ids
    end

    test "search matches array tags" do
      skill = skill_fixture(%{name: "coverage-search", tags: ["coverage-special"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "skill",
                   query: "coverage-special",
                   fields: ["id"]
                 },
                 %{}
               )

      assert result.total_count == 1
      assert result.resources == [%{id: skill.id}]
    end

    test "filters array fields with overlap semantics" do
      matching = skill_fixture(%{name: "coverage-filter-match", tags: ["coverage-tag"]})
      _other = skill_fixture(%{name: "coverage-filter-other", tags: ["different-tag"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "skill",
                   filters: %{"tags" => ["coverage-tag"]},
                   fields: ["id"]
                 },
                 %{}
               )

      assert result.total_count == 1
      assert result.resources == [%{id: matching.id}]
    end

    test "lists channel configs without preloading retrieval channels when not requested" do
      config = channel_config_fixture(%{provider: "mattermost", name: "Mattermost Main"})
      _channel = retrieval_channel_fixture(config, %{channel_name: "Town Square"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "channel_config",
                   query: "Mattermost",
                   fields: ["id", "name"]
                 },
                 %{skip_permissions: true}
               )

      assert [resource] = result.resources
      assert resource.id == config.id
      assert resource.name == "Mattermost Main"
      refute Map.has_key?(resource, :retrieval_channels)
    end

    test "gets channel configs without preloading retrieval channels when not requested" do
      config = channel_config_fixture(%{provider: "mattermost", name: "Mattermost Detail"})
      _channel = retrieval_channel_fixture(config, %{channel_name: "Town Square"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "channel_config",
                   id: config.id,
                   fields: ["id", "name"]
                 },
                 %{skip_permissions: true}
               )

      refute Map.has_key?(result.resource, :retrieval_channels)
      assert result.resource == %{id: config.id, name: "Mattermost Detail"}
    end

    test "serializes NaiveDateTime fields as ISO8601 strings" do
      credential = openai_credential_fixture()
      agent = agent_fixture(credential, %{name: "Timestamp Agent"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   id: agent.id,
                   fields: ["id", "inserted_at", "updated_at"]
                 },
                 %{}
               )

      assert is_binary(result.resource.inserted_at)
      assert is_binary(result.resource.updated_at)
      assert result.resource.inserted_at =~ "T"
      assert result.resource.updated_at =~ "T"
    end

    test "parses string pagination values" do
      credential = openai_credential_fixture()
      _first = agent_fixture(credential, %{name: "String Page A"})
      _second = agent_fixture(credential, %{name: "String Page B"})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   fields: ["id"],
                   limit: "1",
                   offset: "0"
                 },
                 %{}
               )

      assert result.limit == 1
      assert result.offset == 0
      assert length(result.resources) == 1
    end

    test "defaults invalid string pagination values" do
      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   fields: ["id"],
                   limit: "bad",
                   offset: "bad"
                 },
                 %{}
               )

      assert result.limit == 20
      assert result.offset == 0
    end

    test "defaults nil pagination values" do
      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "agent",
                   fields: ["id"],
                   limit: nil,
                   offset: nil
                 },
                 %{}
               )

      assert result.limit == 20
      assert result.offset == 0
    end

    test "actor team ids supplied directly skip the person lookup" do
      actor = person_fixture(%{full_name: "Direct Team Actor"})
      target = person_fixture(%{full_name: "Direct Team Target"})
      {:ok, team} = People.create_team(%{name: "Coverage Team"})

      {:ok, _permission} =
        Permissions.grant(target, %{team_id: team.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "person",
                   query: "Direct Team Target",
                   fields: ["id", "full_name"]
                 },
                 %{actor: %{person: %{id: actor.id, team_ids: [team.id]}}}
               )

      assert result.resources == [%{id: target.id, full_name: "Direct Team Target"}]
    end

    test "missing person data produces empty team ids" do
      actor = person_fixture(%{full_name: "Missing Team Actor"})
      target = person_fixture(%{full_name: "Missing Team Actor Target"})

      Repo.update_all(
        Ecto.Query.from(p in Zaq.Accounts.Person, where: p.id == ^actor.id),
        set: [team_ids: nil]
      )

      {:ok, _permission} =
        Permissions.grant(target, %{person_id: actor.id, access_rights: ["read"]})

      assert {:ok, result} =
               QueryResources.run(
                 %{
                   mode: "query",
                   resource_type: "person",
                   query: "Missing Team Actor Target",
                   fields: ["id", "full_name"]
                 },
                 %{person_id: actor.id}
               )

      assert result.resources == [%{id: target.id, full_name: "Missing Team Actor Target"}]
    end
  end

  defp agent_fixture(credential, attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "Agent #{unique}",
          description: "Test agent",
          job: "Answer questions",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react"
        },
        attrs
      )

    {:ok, agent} = Agent.create_agent(params)
    agent
  end

  defp openai_credential_fixture do
    ai_credential_fixture(%{
      provider: "openai",
      endpoint: "https://api.openai.com/v1"
    })
  end

  defp mcp_fixture(attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "MCP #{unique}",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:#{unique}"
        },
        attrs
      )

    {:ok, endpoint} = MCP.create_mcp_endpoint(params)
    endpoint
  end

  defp person_fixture(attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          full_name: "Person #{unique}",
          email: "person_#{unique}@example.com",
          phone: "+1555#{unique}",
          role: "member",
          status: "active"
        },
        attrs
      )

    {:ok, person} = People.create_person(params)
    person
  end

  defp person_channel_fixture(person, attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          person_id: person.id,
          platform: "email",
          channel_identifier: "channel_#{unique}@example.com",
          weight: 0
        },
        attrs
      )

    {:ok, channel} = %PersonChannel{} |> PersonChannel.changeset(params) |> Repo.insert()
    channel
  end

  defp channel_config_fixture(attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "Routing Config #{unique}",
          provider: "mattermost",
          url: "https://mattermost-#{unique}.example.com",
          token: "token",
          enabled: true,
          kind: "retrieval",
          settings: %{}
        },
        attrs
      )

    {:ok, config} = %ChannelConfig{} |> ChannelConfig.changeset(params) |> Repo.insert()
    config
  end

  defp retrieval_channel_fixture(config, attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          channel_config_id: config.id,
          channel_id: "channel-#{unique}",
          channel_name: "Channel #{unique}",
          team_id: "team-#{unique}",
          team_name: "Team #{unique}",
          active: true
        },
        attrs
      )

    {:ok, channel} = %RetrievalChannel{} |> RetrievalChannel.changeset(params) |> Repo.insert()
    channel
  end

  defp routing_rule_fixture(attrs) do
    params =
      Map.merge(
        %{
          routing_mode: :none
        },
        attrs
      )

    Repo.insert!(struct(IncomingMessageRoutingRule, params))
  end

  defp skill_fixture(attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "coverage-skill-#{unique}",
          description: "Coverage skill #{unique}",
          body: "# Coverage Skill\nUse for coverage.\n",
          tags: ["coverage-default"]
        },
        attrs
      )

    {:ok, skill} = %Skill{} |> Skill.changeset(params) |> Repo.insert()
    skill
  end
end
