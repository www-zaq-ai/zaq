defmodule Zaq.Agent.Skill.ResourceProviderTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Jido.AI.Skill.ResourcePolicy
  alias Jido.AI.Skill.Spec
  alias Zaq.Accounts.People
  alias Zaq.Agent.Skill.ResourceProvider
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Channels.ChannelConfig
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

      send(
        dispatch_target,
        {:resource_access, opts[:action], event.actor, opts[:skip_permissions]}
      )

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

    def dispatch(%Event{next_hop: %{destination: :channels}, opts: opts} = event) do
      Zaq.Channels.Api.handle_event(event, Keyword.fetch!(opts, :action), nil)
    end

    def dispatch(%Event{next_hop: %{destination: :storage}, opts: opts} = event) do
      Zaq.Storage.Api.handle_event(event, Keyword.fetch!(opts, :action), nil)
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

  test "resource reads explicitly bypass permissions while preserving the actor", %{spec: spec} do
    set_router_responses(%{})
    actor = %{person: %{id: Ecto.UUID.generate()}}
    context = %{node_router: Router, actor: actor, skip_permissions: false}

    assert {:ok, %{content: "Hello skill!"}} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1"},
               context
             )

    assert_received {:resource_access, :data_source_get_file, ^actor, true}
    assert_received {:resource_access, :data_source_download_document, ^actor, true}

    assert {:ok, _} =
             Jido.Exec.run(
               GetDocument,
               %{provider: "disk", config_id: "7", document_id: "doc-1"},
               context
             )

    assert_received {:resource_access, :data_source_get_file, ^actor, bypass}
    refute bypass
  end

  @tag :tmp_dir
  test "private disk resources remain denied outside the skill loader", %{
    tmp_dir: root,
    skill: skill,
    spec: spec
  } do
    previous_storage = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})

    on_exit(fn ->
      if previous_storage,
        do: Application.put_env(:zaq, Zaq.Storage, previous_storage),
        else: Application.delete_env(:zaq, Zaq.Storage)
    end)

    File.mkdir_p!(Path.join(root, "resources"))
    File.write!(Path.join(root, "resources/private.md"), "Private skill instructions")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Private skill disk",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "skills", "path" => "resources"}]}
      })
      |> Repo.insert!()

    {:ok, _} = System.save_skill_resource_config(%{provider: "disk", config_id: config.id})

    {:ok, _} =
      Skills.upsert_skill_resource(skill, %{
        provider_resource_id: "skills/private.md",
        name: "private.md",
        resource_type: "asset"
      })

    params = %{
      provider: "disk",
      config_id: to_string(config.id),
      document_id: "skills/private.md"
    }

    {:ok, person} = People.create_person(%{full_name: "Skill user"})

    for actor <- [%{person: %{id: person.id}}, nil] do
      context = %{node_router: Router, actor: actor, skip_permissions: false}

      assert {:error, %{message: "Data source document request failed: :unauthorized"}} =
               Jido.Exec.run(GetDocument, params, context)

      assert {:ok, %{content: "Private skill instructions"}} =
               ResourceProvider.handle(
                 %{operation: :load, skill: spec, resource_id: "skills/private.md"},
                 context
               )

      assert {:error, %{message: "Data source document request failed: :unauthorized"}} =
               Jido.Exec.run(GetDocument, params, context)
    end
  end

  property "unregistered resource IDs never acquire privileged access", %{spec: spec} do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 64)) do
      assert {:error, :not_found} =
               ResourceProvider.handle(
                 %{operation: :load, skill: spec, resource_id: "unregistered-" <> suffix},
                 %{node_router: Router, person_id: nil}
               )

      refute_received {:dispatch, _, _}
    end
  end

  test "rejects inactive skills before privileged access", %{skill: skill, spec: spec} do
    {:ok, _} = Skills.update_skill(skill, %{active: false})

    assert {:error, :skill_not_found} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "doc-1"},
               %{node_router: Router}
             )

    refute_received {:dispatch, _, _}
  end

  test "rejects resources belonging to another skill", %{spec: spec} do
    {:ok, other} =
      Skills.create_skill(%{
        name: "other-skill",
        description: "Other resources",
        body: "Instructions"
      })

    {:ok, _} =
      Skills.upsert_skill_resource(other, %{
        provider_resource_id: "other-doc",
        name: "other.md",
        resource_type: "asset"
      })

    assert {:error, :not_found} =
             ResourceProvider.handle(
               %{operation: :load, skill: spec, resource_id: "other-doc"},
               %{node_router: Router}
             )

    refute_received {:dispatch, _, _}
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
