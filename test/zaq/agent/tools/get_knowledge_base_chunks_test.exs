defmodule Zaq.Agent.Tools.GetKnowledgeBaseChunksTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.GetKnowledgeBaseChunks
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{request: %{chunk_ids: ids, access_opts: opts}} = event) do
      send(event.actor.test_pid, {:fetch_request, ids, opts, event.opts})
      %{event | response: {:ok, %{chunks: [], count: 0, unavailable_ids: Enum.uniq(ids)}}}
    end
  end

  test "validated action fetches one or many IDs with trusted access context" do
    assert {:ok, %{count: 0, unavailable_ids: [3, 7]}} =
             Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: [3, 7, 3]}, %{
               node_router: Router,
               execution_actor: %{test_pid: self()},
               person_id: 42,
               team_ids: [8],
               source_filter: ["allowed"]
             })

    assert_receive {:fetch_request, [3, 7, 3], access, event_opts}
    assert access[:person_id] == 42
    assert access[:team_ids] == [8]
    assert access[:source_filter] == ["allowed"]
    assert access[:skip_permissions] == false
    assert event_opts[:action] == :get_knowledge_base_chunks
  end

  test "malformed or empty ID lists are rejected before dispatch" do
    for ids <- [[], [0], [-1], ["3"], [1.0], nil] do
      assert {:error, _} =
               Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: ids}, %{node_router: Router})
    end

    refute_receive {:fetch_request, _, _, _}
  end

  test "missing identity never implicitly enables permission bypass" do
    assert {:ok, _} =
             Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: [1]}, %{
               node_router: Router,
               execution_actor: %{test_pid: self()}
             })

    assert_receive {:fetch_request, [1], access, _}
    assert access[:skip_permissions] == false
    refute access[:person_id]
  end

  test "workflow contract is satisfied and Registry exposure is intentional" do
    assert :ok = Action.validate(GetKnowledgeBaseChunks)

    assert {:ok, [GetKnowledgeBaseChunks]} =
             Registry.resolve_modules(["answering.get_knowledge_base_chunks"])
  end
end
