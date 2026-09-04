defmodule Zaq.Agent.Skill.ResourceProviderTest do
  use Zaq.DataCase, async: false

  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.Skill.ResourceProvider
  alias Zaq.Agent.Skills
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.System

  defmodule Router do
    def dispatch(
          %Event{
            request: %{provider: "disk", params: %{"file_id" => "doc-1"} = params},
            opts: opts
          } =
            event
        ) do
      send(self(), {:dispatch, opts[:action], params})

      response =
        case opts[:action] do
          :data_source_get_file -> {:ok, %{record: metadata_record()}}
          :data_source_download_document -> {:ok, %{record: content_record()}}
        end

      %{event | response: response}
    end

    defp metadata_record do
      {:ok, handle} =
        DataSourceDocument.issue("disk", "doc-1", %{
          "config_id" => "7",
          "document_mime_type" => "text/markdown"
        })

      %Record{
        id: "doc-1",
        kind: :file,
        name: "guide.md",
        size: 12,
        mime_type: "text/markdown",
        materialization_handle: handle
      }
      |> seal!()
    end

    defp content_record do
      %Record{
        id: "doc-1",
        kind: :file,
        name: "guide.md",
        content: "Hello skill!",
        mime_type: "text/markdown"
      }
      |> seal!()
    end

    defp seal!(record) do
      {:ok, sealed} = Provenance.seal(record, %{"provider" => "disk", "config_id" => "7"})
      sealed
    end
  end

  setup do
    {:ok, _config} =
      System.save_skill_resource_config(%{
        provider: "disk",
        config_id: "7",
        scope_id: "volume-a",
        folder_path: "Skills"
      })

    {:ok, skill} =
      Skills.create_skill(%{
        name: "runtime-skill",
        description: "Runtime skill resources.",
        body: "Use resource files.",
        active: true
      })

    {:ok, _resource} =
      Skills.upsert_skill_resource(skill, %{
        provider_resource_id: "doc-1",
        name: "guide.md",
        resource_type: "asset",
        size: 12,
        mime_type: "text/markdown"
      })

    %{
      skill: skill,
      spec: %Spec{
        name: skill.name,
        description: skill.description,
        body_ref: {:inline, skill.body}
      }
    }
  end

  test "lists skill resources from DB entries", %{spec: spec} do
    assert {:ok,
            %{
              resources: [%{id: "doc-1", name: "guide.md", type: "asset", size: 12}],
              complete: true
            }} =
             ResourceProvider.handle(%{operation: :list, skill: spec, policy: nil}, %{
               node_router: Router
             })
  end

  test "lists no resources without data-source discovery" do
    {:ok, skill} =
      Skills.create_skill(%{
        name: "empty-skill",
        description: "No resources.",
        body: "Use only instructions.",
        active: true
      })

    spec = %Spec{
      name: skill.name,
      description: skill.description,
      body_ref: {:inline, skill.body}
    }

    assert {:ok, %{resources: [], complete: true}} =
             ResourceProvider.handle(%{operation: :list, skill: spec, policy: nil}, %{
               node_router: Router
             })

    refute_received {:dispatch, _, _}
  end

  test "loads a text resource through fresh materialization", %{spec: spec} do
    assert {:ok,
            %{
              content: "Hello skill!",
              resource_id: "doc-1",
              size: 12
            }} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )
  end

  test "rejects unknown resource ids before dispatch", %{spec: spec} do
    assert {:error, :not_found} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "missing", policy: nil},
               %{node_router: Router}
             )

    refute_received {:dispatch, _, _}
  end
end
