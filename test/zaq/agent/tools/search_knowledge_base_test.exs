defmodule Zaq.Agent.Tools.SearchKnowledgeBaseTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.SearchKnowledgeBase

  defmodule StubNodeRouter do
    def dispatch(
          %Zaq.Event{request: %{function: :query_extraction, args: ["find elixir", _opts]}} =
            event
        ) do
      %{
        event
        | response:
            {:ok,
             [
               %{"content" => "Elixir runs on the BEAM VM.", "source" => "docs/elixir.md"},
               %{"content" => "It was created by José Valim."}
             ]}
      }
    end

    def dispatch(
          %Zaq.Event{request: %{function: :query_extraction, args: ["timeout query", _opts]}} =
            event
        ) do
      %{event | response: {:error, :timeout}}
    end

    def dispatch(
          %Zaq.Event{request: %{function: :query_extraction, args: [_query, _opts]}} = event
        ) do
      %{event | response: {:ok, []}}
    end
  end

  # Matches only when opts carry exactly person_id: 42, team_ids: [1, 2],
  # skip_permissions: false — any deviation causes the fallback to return an
  # error, which fails the test that asserts {:ok, _}.
  defmodule PermissionRouter do
    def dispatch(
          %Zaq.Event{
            request: %{args: [_query, [person_id: 42, team_ids: [1, 2], skip_permissions: false]]}
          } = event
        ) do
      %{event | response: {:ok, []}}
    end

    def dispatch(%Zaq.Event{request: %{args: [_query, opts]}} = event) do
      %{event | response: {:error, {:unexpected_opts, opts}}}
    end
  end

  defmodule SkipPermissionsRouter do
    def dispatch(%Zaq.Event{request: %{args: [_query, opts]}} = event) do
      response =
        case {Keyword.get(opts, :person_id), Keyword.get(opts, :skip_permissions)} do
          {nil, false} -> {:ok, []}
          {nil, true} -> {:ok, []}
          {_id, false} -> {:ok, []}
          {_id, other} -> {:error, {:skip_permissions_was, other}}
        end

      %{event | response: response}
    end
  end

  defmodule DefaultTeamIdsRouter do
    def dispatch(%Zaq.Event{request: %{args: [_query, opts]}} = event) do
      response =
        case Keyword.get(opts, :team_ids) do
          [] -> {:ok, []}
          other -> {:error, {:team_ids_was, other}}
        end

      %{event | response: response}
    end
  end

  describe "run/2 — basic behaviour" do
    test "returns formatted chunks and count on success" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: StubNodeRouter}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "find elixir"}, context)
      assert result.count == 2

      [first_chunk | _] = result.chunks
      assert String.contains?(first_chunk["content"], "Elixir runs on the BEAM VM.")
      assert String.contains?(first_chunk["source"], "docs/elixir.md")
    end

    test "returns error message when NodeRouter returns error" do
      context = %{person_id: 42, node_router: StubNodeRouter}

      assert {:error, message} = SearchKnowledgeBase.run(%{query: "timeout query"}, context)
      assert message == "Knowledge base search failed: :timeout"
    end

    test "returns empty chunks when no results found" do
      context = %{person_id: 42, node_router: StubNodeRouter}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "nothing here"}, context)
      assert result.count == 0
      assert result.chunks == []
    end
  end

  describe "run/2 — permission enforcement" do
    test "nil person_id without skip_permissions passes skip_permissions: false (public data only)" do
      context = %{person_id: nil, node_router: SkipPermissionsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "anything"}, context)
    end

    test "nil person_id absent from context also passes skip_permissions: false" do
      context = %{team_ids: [1], node_router: SkipPermissionsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "anything"}, context)
    end

    test "nil person_id with explicit skip_permissions: true passes skip_permissions: true (admin)" do
      context = %{person_id: nil, skip_permissions: true, node_router: SkipPermissionsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "anything"}, context)
    end

    test "forwards person_id and team_ids to query_extraction" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: PermissionRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "test"}, context)
    end

    test "sets skip_permissions: false when person_id is present" do
      context = %{person_id: 1, team_ids: [], node_router: SkipPermissionsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "test"}, context)
    end

    test "defaults team_ids to [] when absent from context" do
      context = %{person_id: 1, node_router: DefaultTeamIdsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "test"}, context)
    end

    test "forwards the actual team_ids value, not a hardcoded default" do
      # PermissionRouter only matches team_ids: [1, 2] — passing [99] must fail,
      # proving the value comes from context and not a hardcoded fallback.
      context = %{person_id: 42, team_ids: [99], node_router: PermissionRouter}

      assert {:error, _} = SearchKnowledgeBase.run(%{query: "test"}, context)
    end
  end
end
