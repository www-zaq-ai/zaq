defmodule Zaq.Agent.SkillResourcesE2ETest do
  @moduledoc """
  The full skill-resource loop: a file written through the disk bridge, recorded on the
  skill, listed by `load_skill`, and read back by `download_document`.

  Nothing between the tools and ingestion is stubbed — the seam is the point.
  """

  # async: false — mounts a volume through Application.put_env.
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Agent.Tools.Skills.LoadSkill
  alias Zaq.Channels.Api, as: ChannelsApi
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document

  @volume "documents"

  # Short-circuits the transport only: channels events reach the real Channels API, and the
  # bridge dispatches on to ingestion from there.
  defmodule RealRouter do
    alias Zaq.Channels.Api, as: ChannelsApi

    def dispatch(%{request: %{provider: _, params: _}} = event) do
      ChannelsApi.handle_event(event, Keyword.fetch!(event.opts, :action), %{})
    end

    def dispatch(%{request: request} = event) do
      %{event | response: Ingestion.materialize_record(request)}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "zaq_skill_res_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.merge(original || [], volumes: %{@volume => root})
    )

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(original),
        do: Application.delete_env(:zaq, Zaq.Ingestion),
        else: Application.put_env(:zaq, Zaq.Ingestion, original)
    end)

    %{root: root}
  end

  defp skill!(attrs) do
    {:ok, skill} =
      Map.merge(
        %{
          name: "pricing-faq",
          description: "Prices and how to quote them.",
          body: "Follow this."
        },
        attrs
      )
      |> Skills.create_skill()

    skill
  end

  defp agent!(skill) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Agent.create_agent(%{
        name: "resource-reader-#{System.unique_integer([:positive])}",
        job: "Read skill references.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_skill_ids: [skill.id]
      })

    agent
  end

  # Writes through the same bridge call the BO makes.
  defp upload!(skill, filename, content) do
    params = %{
      "path" => Path.join(@volume, Resources.references_dir(skill)),
      "name" => filename,
      "content" => Base.encode64(content),
      "encoding" => "base64",
      "tags" => ["public"]
    }

    event =
      Event.new(%{provider: "disk", params: params}, :channels,
        opts: [action: :data_source_create_file]
      )

    {:ok, %{record: record}} =
      ChannelsApi.handle_event(event, :data_source_create_file, %{}).response

    record
  end

  defp ctx(agent), do: %{configured_agent_id: agent.id, node_router: RealRouter}

  test "a skill resource survives upload, load_skill, and download_document", %{root: root} do
    skill = skill!(%{name: "pricing-faq"})
    record = upload!(skill, "prices.md", "# Q3 prices")

    {:ok, skill} =
      Skills.update_skill(skill, %{
        resources:
          Resources.add_references(skill, [
            Resources.entry(record.id, record.name, "disk")
          ])
      })

    agent = agent!(skill)

    # The file really landed on the volume, tagged public.
    assert File.read!(Path.join(root, ".agents/skills/pricing-faq/references/prices.md")) ==
             "# Q3 prices"

    assert "public" in Document.get(record.id).tags

    # load_skill hands the model metadata only.
    assert {:ok, loaded} = LoadSkill.run(%{name: "pricing-faq"}, ctx(agent))
    assert %RecordPage{records: [listed]} = loaded.resources
    assert listed.content == nil
    assert listed.name == "prices.md"

    # The model materializes it with the id and provider the record named.
    assert {:ok, %{record: downloaded}} =
             DownloadDocument.run(
               %{provider: listed.attributes["provider"], document_id: listed.id},
               ctx(agent)
             )

    assert downloaded.content == "# Q3 prices"
  end

  test "a reference whose document was deleted reports an error, not a crash" do
    skill =
      skill!(%{
        name: "stale-skill",
        resources: %{
          "references" => [
            %{"file_id" => "999999", "file_name" => "gone.md", "provider" => "disk"}
          ]
        }
      })

    agent = agent!(skill)

    assert {:ok, loaded} = LoadSkill.run(%{name: "stale-skill"}, ctx(agent))
    assert %RecordPage{records: [listed]} = loaded.resources

    assert {:error, message} =
             DownloadDocument.run(%{provider: "disk", document_id: listed.id}, ctx(agent))

    assert message =~ "Data source document download failed"
  end

  # Documents the gap the permission-enforcement follow-up closes: nothing on this path
  # checks who is asking, so an untagged document is returned exactly like a public one.
  test "reads are not permission-filtered yet" do
    skill = skill!(%{name: "private-skill"})

    params = %{
      "path" => Path.join(@volume, Resources.references_dir(skill)),
      "name" => "private.md",
      "content" => Base.encode64("secret"),
      "encoding" => "base64"
    }

    event =
      Event.new(%{provider: "disk", params: params}, :channels,
        opts: [action: :data_source_create_file]
      )

    {:ok, %{record: record}} =
      ChannelsApi.handle_event(event, :data_source_create_file, %{}).response

    assert Document.get(record.id).tags == []

    agent = agent!(skill)

    assert {:ok, %{record: downloaded}} =
             DownloadDocument.run(
               %{provider: "disk", document_id: record.id},
               Map.put(ctx(agent), :person_id, nil)
             )

    assert downloaded.content == "secret"
  end
end
