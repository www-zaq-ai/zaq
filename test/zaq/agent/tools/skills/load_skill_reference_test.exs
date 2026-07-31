defmodule Zaq.Agent.Tools.Skills.LoadSkillReferenceTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Agent.Tools.Skills.LoadSkillReference

  @locator ".agents/skills/calculator"

  defp skill!(attrs) do
    {:ok, skill} =
      %{
        name: "calculator",
        description: "Precise arithmetic.",
        body: "# Calculator",
        resource_root: @locator,
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

  # Two hops now, not one: the tool asks ingestion what the bundle holds, then hands the
  # record it found back to be materialized. The stub serves both, so a test can still say
  # "this file contains X" in one line.
  defmodule RecordingRouter do
    alias Zaq.Ingestion.BundleRecords

    def dispatch(event) do
      send(self(), {:dispatched, event.next_hop.destination, event.opts[:action], event.request})
      %{event | response: respond(event.opts[:action], event.request)}
    end

    defp respond(:list_skill_bundle, %{bundle: locator}) do
      case Process.get(:listing_response) do
        nil -> {:ok, BundleRecords.from_listing(entries(), locator)}
        override -> override
      end
    end

    defp respond(:materialize_record, %{record: record}) do
      case Process.get(:bundle_response) do
        {:ok, text} -> {:ok, %{record | content: text, size: byte_size(text)}}
        other -> other
      end
    end

    defp entries do
      Process.get(:bundle_paths, [])
      |> Enum.group_by(&(&1 |> Path.split() |> hd() |> String.to_atom()))
      |> Map.new(fn {type, paths} -> {type, Enum.map(paths, &entry/1)} end)
    end

    defp entry(path) do
      %{
        name: Path.basename(path),
        relative_path: path,
        size: Process.get(:bundle_size, 12),
        modified: ~U[2026-07-30 12:00:00Z]
      }
    end
  end

  defmodule RaisingTelemetry do
    def execute(_event, _measurements, _metadata), do: raise("telemetry offline")
  end

  # `paths` is what the bundle is said to contain. It matters: the tool will only materialize
  # a file that appears in the listing, so a test that forgets to declare its path gets the
  # same not-found a model would.
  defp ctx(agent, response, opts \\ []) do
    Process.put(:bundle_response, response)
    Process.put(:listing_response, Keyword.get(opts, :listing))
    Process.put(:bundle_size, Keyword.get(opts, :size, 12))

    Process.put(
      :bundle_paths,
      Keyword.get(opts, :paths, ["references/pricing.md", "assets/notes.txt"])
    )

    %{configured_agent_id: agent.id, node_router: RecordingRouter}
  end

  defp granted!(skill_attrs \\ %{}) do
    skill = skill!(skill_attrs)
    {skill, agent!(%{enabled_skill_ids: [skill.id]})}
  end

  describe "reading a granted skill's resource" do
    test "returns the file's text" do
      {_skill, agent} = granted!()

      assert {:ok, result} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/pricing.md"},
                 ctx(agent, {:ok, "# Pricing 2026"})
               )

      assert result.skill_name == "calculator"
      assert result.resource_path == "references/pricing.md"
      assert result.content == "# Pricing 2026"
    end

    test "dispatches exactly %{record: record}, with the descriptor ingestion minted" do
      {_skill, agent} = granted!()

      LoadSkillReference.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "body"})
      )

      assert_receive {:dispatched, :ingestion, :materialize_record, request}
      assert Map.keys(request) == [:record]

      descriptor = request.record.materialization
      assert descriptor.role == :ingestion
      assert descriptor.strategy == :skill_bundle
      assert descriptor.params == %{locator: @locator, resource_path: "references/pricing.md"}
    end

    # `as: :text` is what keeps base64 out of the context window; the cap is pushed down so
    # ingestion refuses before it reads rather than after it ships.
    test "narrows the descriptor to text and the read cap" do
      {_skill, agent} = granted!()

      LoadSkillReference.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "body"})
      )

      assert_receive {:dispatched, :ingestion, :materialize_record, %{record: record}}
      assert record.materialization.as == :text

      assert record.materialization.max_bytes ==
               Limits.get(:resource_read_max_bytes)
    end

    test "no volume is named anywhere in the dispatched record" do
      {_skill, agent} = granted!()

      LoadSkillReference.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "body"})
      )

      assert_receive {:dispatched, :ingestion, :materialize_record, %{record: record}}
      refute inspect(record) =~ "volume"
    end

    test "passes the resource_path through byte-for-byte" do
      # The manifest handed the model this exact string; rewriting it here could only let it
      # reach a file it did not name.
      {_skill, agent} = granted!()
      path = "references/sub dir/Q3 Report (final).md"

      LoadSkillReference.run(
        %{skill_name: "calculator", resource_path: path},
        ctx(agent, {:ok, "body"}, paths: [path])
      )

      assert_receive {:dispatched, :ingestion, :materialize_record, %{record: record}}
      assert record.path == path
      assert record.materialization.params.resource_path == path
    end

    # The capability property: only a file the live listing actually contains can be read.
    test "a path absent from the listing is not found, and nothing is materialized" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/not-listed.md"},
                 ctx(agent, {:ok, "SHOULD NOT BE REACHED"})
               )

      assert message =~ "not a file bundled with"
      refute_receive {:dispatched, _, :materialize_record, _}
    end

    test "reads an asset that happens to be text" do
      {_skill, agent} = granted!()

      assert {:ok, result} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "assets/notes.txt"},
                 ctx(agent, {:ok, "plain"})
               )

      assert result.content == "plain"
    end
  end

  describe "scoping — the security boundary" do
    test "a skill not attached to this agent is refused" do
      _skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/pricing.md"},
                 ctx(agent, {:ok, "SHOULD NOT BE REACHED"})
               )

      assert message =~ "not available to this agent"
      refute_receive {:dispatched, _, _, _}
    end

    test "the refusal names neither the file nor any other skill" do
      granted = skill!(%{name: "calculator"})
      _other = skill!(%{name: "top-secret-other-skill", resource_root: ".agents/skills/other"})
      agent = agent!(%{enabled_skill_ids: [granted.id]})

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "nope", resource_path: "references/salaries.md"},
                 ctx(agent, {:ok, "x"})
               )

      refute message =~ "top-secret-other-skill"
      refute message =~ "salaries"
      refute message =~ "calculator"
    end

    test "agent B cannot read agent A's skill resource" do
      skill_a = skill!(%{name: "for-agent-a", resource_root: ".agents/skills/for-agent-a"})
      _agent_a = agent!(%{enabled_skill_ids: [skill_a.id]})
      agent_b = agent!(%{enabled_skill_ids: []})

      assert {:error, _} =
               LoadSkillReference.run(
                 %{skill_name: "for-agent-a", resource_path: "references/a.md"},
                 ctx(agent_b, {:ok, "leak"})
               )
    end

    test "an inactive skill reads as not-granted" do
      skill = skill!(%{name: "calculator", active: false})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, _} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:ok, "leak"}, paths: ["references/a.md"])
               )
    end

    test "nil configured_agent_id is refused, never a global lookup" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 %{node_router: RecordingRouter}
               )

      assert message =~ "not available in this context"
      refute_receive {:dispatched, _, _, _}
    end

    test "an unknown configured_agent_id is refused" do
      _skill = skill!(%{name: "calculator"})

      assert {:error, _} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 %{configured_agent_id: 999_999, node_router: RecordingRouter}
               )
    end
  end

  describe "path refusals" do
    test "a scripts/ path is refused without dispatching" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "scripts/deploy.sh"},
                 ctx(agent, {:ok, "rm -rf /"})
               )

      assert message =~ "Scripts are not readable"
      refute_receive {:dispatched, _, _, _}
    end

    test "a nested scripts/ path is refused too" do
      {_skill, agent} = granted!()

      assert {:error, _} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "scripts/nested/deploy.sh"},
                 ctx(agent, {:ok, "payload"})
               )

      refute_receive {:dispatched, _, _, _}
    end

    # A traversal string cannot appear in a bundle listing, so it collapses into the same
    # not-found as any other unlisted path. That is stronger than a distinct message: the
    # model learns nothing about which paths are shaped correctly.
    test "traversal is refused, and nothing is materialized" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "../../../etc/passwd"},
                 ctx(agent, {:error, :path_traversal})
               )

      assert message =~ "not a file bundled with"
      refute_receive {:dispatched, _, :materialize_record, _}
    end

    test "an absolute path is refused, and nothing is materialized" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "/etc/passwd"},
                 ctx(agent, {:error, :path_traversal})
               )

      assert message =~ "not a file bundled with"
      refute_receive {:dispatched, _, :materialize_record, _}
    end

    # A bare filename is not silently resolved against `references/`: the listing carries
    # full paths, so only a full path matches.
    test "a bare filename is refused even when that file exists under references/" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "pricing.md"},
                 ctx(agent, {:error, :invalid_resource_path})
               )

      assert message =~ "not a file bundled with"
      refute_receive {:dispatched, _, :materialize_record, _}
    end
  end

  describe "content failures are usable messages, not crashes" do
    test "a binary resource explains itself" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "assets/logo.png"},
                 ctx(agent, {:error, :invalid_utf8}, paths: ["assets/logo.png"])
               )

      assert message =~ "binary file"
      assert message =~ "cannot be read as text"
    end

    test "a missing file points back at load_skill" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/absent.md"},
                 ctx(agent, {:error, :not_found}, paths: ["references/absent.md"])
               )

      assert message =~ "load_skill"
    end

    test "a skill with no bundle says so" do
      skill = skill!(%{name: "calculator", resource_root: nil})
      agent = agent!(%{enabled_skill_ids: [skill.id]})

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:ok, "unused"}, paths: ["references/a.md"])
               )

      assert message =~ "no bundled files"
      refute_receive {:dispatched, _, _, _}
    end

    test "an unreachable ingestion node degrades to a retryable message" do
      {_skill, agent} = granted!()

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 ctx(agent, {:error, :no_volumes}, paths: ["references/a.md"])
               )

      assert message =~ "could not be read right now"
    end
  end

  describe "the read cap" do
    test "an oversize file is refused with its size named, not truncated" do
      {_skill, agent} = granted!()
      body = String.duplicate("x", 300_000)

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/huge.md"},
                 ctx(agent, {:ok, body}, paths: ["references/huge.md"])
               )

      assert message =~ "300000 bytes"
      assert message =~ "262144"
      refute message =~ "xxxx"
    end

    test "a file exactly at the cap is returned" do
      {_skill, agent} = granted!()
      body = String.duplicate("x", 262_144)

      assert {:ok, result} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/exact.md"},
                 ctx(agent, {:ok, body}, paths: ["references/exact.md"])
               )

      assert byte_size(result.content) == 262_144
    end

    test "the cap is overridable" do
      {_skill, agent} = granted!()

      context =
        agent
        |> ctx({:ok, "0123456789"}, paths: ["references/small.md"])
        |> Map.put(:limits_opts, config: __MODULE__.TinyLimits)

      assert {:error, message} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/small.md"},
                 context
               )

      assert message =~ "10 bytes"
    end

    defmodule TinyLimits do
      def get(:zaq, :agent_skills, _default, _opts), do: %{resource_read_max_bytes: 4}
      def get(app, key, default, _opts), do: Application.get_env(app, key, default)
    end
  end

  describe "telemetry" do
    test "emits bytes and tokens for the returned file" do
      {skill, agent} = granted!()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:zaq, :agent, :skill, :resource_load]])

      LoadSkillReference.run(
        %{skill_name: "calculator", resource_path: "references/pricing.md"},
        ctx(agent, {:ok, "one two three four five"})
      )

      assert_receive {[:zaq, :agent, :skill, :resource_load], ^ref, measurements, metadata}
      assert measurements.bytes == byte_size("one two three four five")
      assert measurements.tokens > 0
      assert metadata.skill_name == "calculator"
      assert metadata.skill_id == skill.id
      assert metadata.resource_path == "references/pricing.md"
      assert metadata.configured_agent_id == agent.id
    end

    test "a telemetry failure does not fail the call" do
      {_skill, agent} = granted!()

      context =
        agent
        |> ctx({:ok, "body"}, paths: ["references/a.md"])
        |> Map.put(:telemetry_module, RaisingTelemetry)

      assert {:ok, result} =
               LoadSkillReference.run(
                 %{skill_name: "calculator", resource_path: "references/a.md"},
                 context
               )

      assert result.content == "body"
    end
  end

  describe "auto-provisioning" do
    test "appears with the first skill and disappears with the last" do
      skill = skill!(%{name: "calculator"})
      agent = agent!(%{enabled_skill_ids: []})

      assert "skills.load_skill_reference" not in Skills.provisioned_tool_keys(agent, [])

      keys = Skills.provisioned_tool_keys(agent, [skill])
      assert "skills.load_skill_reference" in keys
      assert "skills.load_skill" in keys
    end

    test "is a valid registry key" do
      assert Zaq.Agent.Tools.Registry.valid_tool_key?("skills.load_skill_reference")
    end

    test "rides the same condition as load_skill" do
      # Splitting them would let the tool vanish mid-conversation while a manifest the model
      # already read still points at it.
      skill = skill!(%{name: "calculator", resource_root: nil})
      agent = agent!(%{enabled_skill_ids: []})

      keys = Skills.provisioned_tool_keys(agent, [skill])
      assert "skills.load_skill_reference" in keys
    end
  end
end
