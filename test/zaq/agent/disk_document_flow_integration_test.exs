defmodule Zaq.Agent.DiskDocumentFlowIntegrationTest do
  @moduledoc """
  Four incoming messages use the real disk datasource through Executor/Factory/Jido.
  Files live in a unique directory of the existing default volume. The test is
  synchronous because ServerManager's startup database reads use one shared PID,
  which cannot belong to multiple independent SQL Sandbox owners concurrently.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Executor
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Storage
  alias Zaq.Storage.EntryCatalog
  alias Zaq.TestSupport.{IntegrationAgent, ToolCallingLLMStub}

  @source_content "# Disk flow source\nExact UTF-8 content: café — 42.\n"
  @created_content "# Created by the agent\nPersist these exact bytes.\n"
  @tools ~w(search_documents download_document create_document list_documents)

  setup do
    namespace = "agent-disk-flow-#{Ecto.UUID.generate()}"
    directory = "#{namespace}/workspace"
    path = "default/#{directory}"
    {:ok, owned_root} = Storage.resolve_path("default", namespace)
    {:ok, absolute_dir} = Storage.resolve_path("default", directory)
    File.mkdir_p!(absolute_dir)
    on_exit(fn -> File.rm_rf!(owned_root) end)
    File.write!(Path.join(absolute_dir, "source.md"), @source_content)
    neighbor = Path.join(owned_root, "neighbor")
    File.mkdir!(neighbor)
    File.write!(Path.join(neighbor, "source.md"), "Unrelated document; leave unchanged.")

    disk_config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Disk #{directory}",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "default", "path" => "."}]}
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Reader #{directory}"})
    {:ok, folder} = EntryCatalog.ensure("default", namespace, "directory")
    {:ok, source} = EntryCatalog.ensure("default", "#{directory}/source.md", "file")
    {:ok, _neighbor} = EntryCatalog.ensure("default", "#{namespace}/neighbor/source.md", "file")

    {:ok, _grant} =
      Storage.grant_document_access(
        folder.id,
        %{person_id: person.id, access_rights: ["read", "write"]}
      )

    scope = %{
      directory: directory,
      path: path,
      absolute_dir: absolute_dir,
      neighbor: neighbor,
      config_id: to_string(disk_config.id),
      person: person,
      source: source
    }

    {:ok, Map.put(scope, :agent, configured_agent(scope))}
  end

  test "search, download, create and list preserve disk identity and content", context do
    search =
      ask(context, "Search disk documents for source.md", "search_documents", %{
        provider: "disk",
        config_id: context.config_id,
        path: context.path,
        query: "source.md"
      })

    assert search["count"] == 1
    assert [found] = search["records"]
    assert found["id"] == context.source.id
    assert found["name"] == "source.md"
    assert found["content"] == nil
    handle = found["materialization_handle"]
    assert is_binary(handle)
    assert String.starts_with?(handle, "mat_")

    downloaded =
      ask(context, "Download disk document #{handle}", "download_document", %{
        materialization_handle: handle
      })

    assert downloaded["record"]["content"] == @source_content

    created =
      ask(
        context,
        "Create disk document created.md with content:\n#{@created_content}",
        "create_document",
        %{
          provider: "disk",
          config_id: context.config_id,
          path: context.path,
          name: "created.md",
          content: @created_content
        }
      )

    assert created["record"]["name"] == "created.md"
    assert created["record"]["id"] != found["id"]
    assert File.read!(Path.join(context.absolute_dir, "created.md")) == @created_content
    assert File.read!(Path.join(context.absolute_dir, "source.md")) == @source_content

    listing =
      ask(context, "List disk documents", "list_documents", %{
        provider: "disk",
        config_id: context.config_id,
        path: context.path
      })

    assert listing["count"] == 2

    assert Map.new(listing["records"], &{&1["name"], &1["id"]}) ==
             %{"source.md" => found["id"], "created.md" => created["record"]["id"]}

    assert Enum.sort(File.ls!(context.absolute_dir)) == ["created.md", "source.md"]
    assert File.ls!(context.neighbor) == ["source.md"]

    assert File.read!(Path.join(context.neighbor, "source.md")) ==
             "Unrelated document; leave unchanged."

    refute_received {:llm_stub_error, _}
    refute_received {:llm_tool_call, _, _}
    refute_received {:llm_tool_result, _, _}
    refute_received {:openai_request, _, _, _, _}
  end

  defp ask(context, message, tool, arguments) do
    incoming = %Incoming{
      content: message,
      channel_id: context.directory,
      provider: :web,
      person: context.person
    }

    outgoing =
      Executor.run(incoming, agent_id: to_string(context.agent.id), scope: context.directory)

    assert_received {:llm_tool_call, ^tool, observed_arguments}
    assert observed_arguments == arguments |> Jason.encode!() |> Jason.decode!()
    assert_received {:llm_tool_result, ^tool, result}
    assert result["ok"] == true, inspect(result)
    assert outgoing.metadata.error == false
    assert outgoing.body == "Observed #{tool}: #{Jason.encode!(result)}"

    for _ <- 1..2 do
      assert_received {:openai_request, "POST", "/v1/responses", _, body}
      names = body |> Jason.decode!() |> Map.fetch!("tools") |> Enum.map(& &1["name"])
      assert Enum.sort(names) == Enum.sort(@tools)
    end

    result["result"]
  end

  defp configured_agent(context) do
    common = %{provider: "disk", config_id: context.config_id, path: context.path}

    routes = [
      %{
        match: &String.contains?(&1, "Search disk documents for "),
        tool: "search_documents",
        arguments: fn message ->
          Map.put(common, :query, after_marker(message, "Search disk documents for "))
        end
      },
      %{
        match: &String.contains?(&1, "Download disk document "),
        tool: "download_document",
        arguments: fn message ->
          %{materialization_handle: after_marker(message, "Download disk document ")}
        end
      },
      %{
        match: &String.contains?(&1, "Create disk document "),
        tool: "create_document",
        arguments: fn message ->
          [name, content] =
            message
            |> after_marker("Create disk document ")
            |> String.split(" with content:\n", parts: 2)

          Map.merge(common, %{name: name, content: content})
        end
      },
      %{
        match: &String.contains?(&1, "List disk documents"),
        tool: "list_documents",
        arguments: fn _ -> common end
      }
    ]

    {child, endpoint} =
      ToolCallingLLMStub.server(routes,
        max_interactions: 4,
        final_response: fn %{tool: tool, tool_result: result} ->
          "Observed #{tool}: #{Jason.encode!(result)}"
        end
      )

    start_supervised!(child)

    IntegrationAgent.create!(
      endpoint,
      context.directory,
      "Use the enabled disk tools to fulfill each request.",
      Enum.map(@tools, &("data_source." <> &1))
    )
  end

  defp after_marker(message, marker), do: message |> String.split(marker, parts: 2) |> List.last()
end
