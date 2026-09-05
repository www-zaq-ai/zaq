defmodule Zaq.Agent.Skill.ResourceProviderTest do
  use Zaq.DataCase, async: false

  alias Jido.AI.Skill.ResourcePolicy
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
      dispatch_target = :persistent_term.get({__MODULE__, :dispatch_target}, self())
      send(dispatch_target, {:dispatch, opts[:action], params})

      overrides =
        Process.get(
          :resource_provider_router_responses,
          :persistent_term.get({__MODULE__, :responses}, %{})
        )

      response =
        case Map.fetch(overrides, opts[:action]) do
          {:ok, response} ->
            response

          :error ->
            case opts[:action] do
              :data_source_get_file -> {:ok, %{record: metadata_record()}}
              :data_source_download_document -> {:ok, %{record: content_record()}}
            end
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

  test "decodes a base64 binary resource with filename and MIME metadata", %{spec: spec} do
    bytes = <<137, "PNG", 13, 10, 26, 10, 0, 1, 2>>

    set_router_responses(%{
      data_source_download_document:
        {:ok,
         %{
           record:
             content_record(
               content: Base.encode64(bytes),
               name: "diagram.png",
               mime_type: "image/png",
               size: byte_size(bytes),
               attributes: %{"encoding" => "base64"}
             )
         }}
    })

    assert {:ok,
            %{
              content: ^bytes,
              filename: "diagram.png",
              mime_type: "image/png",
              resource_id: "doc-1",
              size: 11
            }} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )
  end

  test "satisfies Jido's provider contract for binary resources", %{spec: spec} do
    bytes = <<137, "PNG", 13, 10, 26, 10, 0, 1, 2>>

    set_router_responses(%{
      data_source_download_document:
        {:ok,
         %{
           record:
             content_record(
               content: Base.encode64(bytes),
               name: "diagram.png",
               mime_type: "image/png",
               attributes: %{"encoding" => "base64"}
             )
         }}
    })

    policy = %{ResourcePolicy.default() | binary: :allow}

    assert {:ok,
            %{
              content: ^bytes,
              filename: "diagram.png",
              kind: :image,
              mime_type: "image/png",
              resource_id: "doc-1",
              size: 11
            }} =
             Jido.AI.Skill.ResourceProvider.load(
               {ResourceProvider, :handle},
               spec,
               "doc-1",
               policy,
               %{node_router: Router}
             )
  end

  test "rejects malformed base64 resource content", %{spec: spec} do
    set_router_responses(%{
      data_source_download_document:
        {:ok,
         %{
           record:
             content_record(
               content: "not base64!",
               name: "diagram.png",
               mime_type: "image/png",
               attributes: %{"encoding" => "base64"}
             )
         }}
    })

    assert {:error, :invalid_encoding} =
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

  test "returns skill_not_found for an absent skill", %{spec: spec} do
    absent_spec = %{spec | name: "missing-skill"}

    assert {:error, :skill_not_found} =
             ResourceProvider.handle(%{operation: :list, skill: absent_spec, policy: nil}, %{
               node_router: Router
             })

    refute_received {:dispatch, _, _}
  end

  test "rejects unsupported skill resource requests", %{spec: spec} do
    assert {:error, :unsupported_skill_resource_request} =
             ResourceProvider.handle(%{operation: :delete, skill: spec, policy: nil}, %{
               node_router: Router
             })
  end

  test "returns an error when the resource location is not configured", %{spec: spec} do
    {:ok, _config} = System.save_skill_resource_config(%{})

    assert {:error, :skill_resource_location_not_configured} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )

    refute_received {:dispatch, _, _}
  end

  test "returns an error when metadata has no materialization handle", %{spec: spec} do
    set_router_responses(%{
      data_source_get_file: {:ok, %{record: metadata_record(materialization_handle: nil)}}
    })

    assert {:error, :materialization_handle_missing} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )

    assert_received {:dispatch, :data_source_get_file, _}
    refute_received {:dispatch, :data_source_download_document, _}
  end

  test "returns an error when metadata lookup fails", %{spec: spec} do
    set_router_responses(%{data_source_get_file: {:error, :timeout}})

    assert {:error, %{message: "Data source document request failed: :timeout"}} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )

    refute_received {:dispatch, :data_source_download_document, _}
  end

  test "returns an error when document download fails", %{spec: spec} do
    set_router_responses(%{data_source_download_document: {:error, :timeout}})

    assert {:error, %{message: "Record materialization failed: :timeout"}} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )

    assert_received {:dispatch, :data_source_get_file, _}
    assert_received {:dispatch, :data_source_download_document, _}
  end

  test "returns an error when materialized content is not textual", %{spec: spec} do
    set_router_responses(%{
      data_source_download_document:
        {:ok, %{record: content_record(content: ["structured", "content"])}}
    })

    assert {:error, :binary_resource} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1", policy: nil},
               %{node_router: Router}
             )

    assert_received {:dispatch, :data_source_get_file, _}
    assert_received {:dispatch, :data_source_download_document, _}
  end

  defp set_router_responses(responses) do
    Process.put(:resource_provider_router_responses, responses)
    :persistent_term.put({Router, :responses}, responses)
    :persistent_term.put({Router, :dispatch_target}, self())

    on_exit(fn ->
      Process.delete(:resource_provider_router_responses)
      :persistent_term.erase({Router, :responses})
      :persistent_term.erase({Router, :dispatch_target})
    end)
  end

  defp metadata_record(attrs) do
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
    |> Map.merge(Map.new(attrs))
    |> seal_record()
  end

  defp content_record(attrs) do
    %Record{
      id: "doc-1",
      kind: :file,
      name: "guide.md",
      content: "Hello skill!",
      mime_type: "text/markdown"
    }
    |> Map.merge(Map.new(attrs))
    |> seal_record()
  end

  defp seal_record(record) do
    {:ok, sealed} = Provenance.seal(record, %{"provider" => "disk", "config_id" => "7"})
    sealed
  end
end
