defmodule Zaq.Agent.Tools.Skills.LoadSkillTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Skills.LoadSkill

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic.",
        body: "# Calculator\nUse the tools, not mental math.",
        tags: []
      }
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  defp agent!(attrs) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      %{
        name: "assistant-#{System.unique_integer([:positive])}",
        job: "Help.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: []
      }
      |> Map.merge(attrs)
      |> Agent.create_agent()

    agent
  end

  defp ctx(agent), do: %{configured_agent_id: agent.id}

  defmodule RaisingTelemetry do
    def execute(_event, _measurements, _metadata), do: raise("telemetry offline")
  end

  defmodule ListRouter do
    alias Zaq.Contracts.Record
    alias Zaq.Contracts.RecordPage
    alias Zaq.Event

    def dispatch(%Event{request: %{provider: provider, params: params}, opts: opts} = event) do
      send(self(), {:listed, provider, opts[:action], params["file_ids"]})

      records =
        Enum.map(params["file_ids"], fn id ->
          %Record{id: id, kind: :file, name: "file-#{id}.md", content: nil, size: 10}
        end)

      %{event | response: {:ok, %RecordPage{resource_type: :file, records: records}}}
    end
  end

  defmodule DownRouter do
    def dispatch(%Zaq.Event{} = event), do: %{event | response: {:error, :node_down}}
  end

  # A reference whose document was deleted comes back as a shorter page, not an error.
  defmodule PartialRouter do
    alias Zaq.Contracts.Record
    alias Zaq.Contracts.RecordPage
    alias Zaq.Event

    def dispatch(%Event{request: %{params: params}} = event) do
      [first | _] = params["file_ids"]
      record = %Record{id: first, kind: :file, name: "survivor.md", content: nil}

      %{event | response: {:ok, %RecordPage{resource_type: :file, records: [record]}}}
    end
  end

  defp with_references(skill, references) do
    {:ok, updated} = Skills.update_skill(skill, %{"resources" => %{"references" => references}})
    updated
  end

  defp disk_refs(ids), do: Enum.map(ids, &%{"file_id" => &1, "provider" => "disk"})

  describe "loading a granted skill" do
    test "returns the skill's full instructions" do
      skill = skill!(%{name: "calculator", body: "SECRET_INSTRUCTIONS"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} = LoadSkill.run(%{name: "calculator"}, ctx(agent))

      assert result.name == "calculator"
      assert result.instructions == "SECRET_INSTRUCTIONS"
      assert result.resources == []
    end

    test "a skill with no references dispatches nothing at all" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, DownRouter))

      assert result.resources == []
    end
  end

  # Exercises Jido's validation pipeline rather than `run/2` directly — `run/2` bypasses
  # both hooks, so a schema that cannot accept a real tool call still passes every
  # behavioural test.
  describe "Zoi schema at the tool boundary" do
    test "accepts the string-keyed params a model actually sends" do
      assert {:ok, %{name: "pricing-faq"}} =
               LoadSkill.validate_params(%{"name" => "pricing-faq"})
    end

    test "rejects a call with no skill name" do
      assert {:error, _} = LoadSkill.validate_params(%{})
    end

    test "accepts output carrying resources" do
      output = %{
        name: "s",
        instructions: "b",
        resources: [%{id: "1", name: "a.md", provider: "disk"}]
      }

      assert {:ok, _} = LoadSkill.validate_output(output)
    end

    test "accepts output with no resources" do
      assert {:ok, _} = LoadSkill.validate_output(%{name: "s", instructions: "b", resources: []})
    end

    # The schema is what stops a half-built entry — one missing the provider — from ever
    # reaching the model.
    test "rejects a resource entry missing the provider" do
      output = %{name: "s", instructions: "b", resources: [%{id: "1", name: "a.md"}]}

      assert {:error, _} = LoadSkill.validate_output(output)
    end
  end

  describe "resources" do
    test "lists one entry per reference, with id, name and provider" do
      skill = skill!(%{name: "calculator"}) |> with_references(disk_refs(["7", "9"]))
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, ListRouter))

      assert result.resources == [
               %{id: "7", name: "file-7.md", provider: "disk"},
               %{id: "9", name: "file-9.md", provider: "disk"}
             ]

      assert_received {:listed, "disk", :data_source_list_files, ["7", "9"]}
    end

    # Regression: `provider` is a required argument of `download_document`, and a model
    # handed only an id invents one — "internal" was observed in practice. It is part of
    # the address, not description, so it must travel with every entry.
    test "every entry carries the provider needed to call download_document" do
      references = disk_refs(["1"]) ++ [%{"file_id" => "2", "provider" => "google_drive"}]
      skill = skill!(%{name: "calculator"}) |> with_references(references)
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, %{resources: resources}} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, ListRouter))

      # Each entry names the provider that actually holds it — not one blanket default.
      by_id = Map.new(resources, &{&1.id, &1.provider})
      assert by_id == %{"1" => "disk", "2" => "google_drive"}
      refute Enum.any?(resources, &is_nil(&1.provider))
    end

    # Records must reach the model unmaterialized — no bytes, and above all no
    # materializing event, which would be a dispatchable capability in a tool result.
    test "surfaces no content and no materializing event" do
      skill = skill!(%{name: "calculator"}) |> with_references(disk_refs(["7"]))
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, %{resources: [entry]}} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, ListRouter))

      assert Map.keys(entry) |> Enum.sort() == [:id, :name, :provider]
    end

    test "issues one dispatch per provider, not one per file" do
      references = disk_refs(["1", "2"]) ++ [%{"file_id" => "3", "provider" => "google_drive"}]
      skill = skill!(%{name: "calculator"}) |> with_references(references)
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, _} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, ListRouter))

      assert_received {:listed, "disk", _, ["1", "2"]}
      assert_received {:listed, "google_drive", _, ["3"]}
      refute_received {:listed, _, _, _}
    end

    # The degraded path: a skill whose instructions need no file must survive the ingestion
    # role being unreachable.
    test "returns the body with no resources when the lookup fails" do
      skill =
        skill!(%{name: "calculator", body: "STILL HERE"}) |> with_references(disk_refs(["7"]))

      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(%{name: "calculator"}, Map.put(ctx(agent), :node_router, DownRouter))

      assert result.instructions == "STILL HERE"
      assert result.resources == []
    end

    test "omits a reference whose document no longer exists" do
      skill = skill!(%{name: "calculator"}) |> with_references(disk_refs(["7", "gone"]))
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, %{resources: [%{id: "7"}]}} =
               LoadSkill.run(
                 %{name: "calculator"},
                 Map.put(ctx(agent), :node_router, PartialRouter)
               )
    end

    test "is idempotent — a repeat call returns the body again, not an error" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, first} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert {:ok, second} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert first == second
    end

    test "telemetry failures do not fail the tool call" do
      skill = skill!(%{name: "calculator", body: "one two three"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:ok, result} =
               LoadSkill.run(
                 %{name: "calculator"},
                 Map.put(ctx(agent), :telemetry_module, RaisingTelemetry)
               )

      assert result.name == "calculator"
      assert result.instructions == skill.body
    end
  end

  describe "scoping — the security boundary" do
    test "an agent cannot load a skill it was never granted" do
      _skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert {:error, message} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
      assert message =~ "not available to this agent"
    end

    test "agent B cannot load agent A's skill" do
      skill_a = skill!(%{name: "for-agent-a"})
      _agent_a = agent!(%{enabled_skill_ids: [skill_a.id]})
      agent_b = agent!(%{enabled_skill_ids: []})

      assert {:error, _} = LoadSkill.run(%{name: "for-agent-a"}, ctx(agent_b))
    end

    test "an inactive skill reads as not-granted" do
      skill = skill!(%{name: "calculator", active: false})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, _} = LoadSkill.run(%{name: "calculator"}, ctx(agent))
    end

    test "a hallucinated name is a clean not-found" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, message} = LoadSkill.run(%{name: "does-not-exist"}, ctx(agent))
      assert message =~ "does-not-exist"
    end

    # Upstream Jido's LoadSkill lists every available skill on a miss (G3). ZAQ must not.
    test "the not-found error leaks no other skill names" do
      granted = skill!(%{name: "calculator"})
      _other = skill!(%{name: "top-secret-other-skill"})
      agent = agent!(%{enabled_skill_ids: [granted.id]})

      assert {:error, message} = LoadSkill.run(%{name: "nope"}, ctx(agent))

      refute message =~ "top-secret-other-skill"
      refute message =~ "calculator"
    end
  end

  describe "context guards" do
    test "no configured_agent_id in context → refused, never a global lookup" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, message} = LoadSkill.run(%{name: "calculator"}, %{})
      assert message =~ "not available in this context"
    end

    test "an unknown configured_agent_id → refused" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, _} = LoadSkill.run(%{name: "calculator"}, %{configured_agent_id: 999_999})
    end
  end

  describe "telemetry" do
    test "emits bytes and tokens for the loaded body" do
      skill = skill!(%{name: "calculator", body: "one two three four five"})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:zaq, :agent, :skill, :load]])

      LoadSkill.run(%{name: "calculator"}, ctx(agent))

      assert_receive {[:zaq, :agent, :skill, :load], ^ref, measurements, metadata}
      assert measurements.body_bytes == byte_size(skill.body)
      assert measurements.body_tokens > 0
      assert metadata.skill_name == "calculator"
      assert metadata.configured_agent_id == agent.id
    end
  end
end
