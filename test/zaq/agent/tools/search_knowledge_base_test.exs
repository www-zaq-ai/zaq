defmodule Zaq.Agent.Tools.SearchKnowledgeBaseTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.SearchKnowledgeBase

  defmodule StubNodeRouter do
    def call(:ingestion, _mod, :query_extraction, ["find elixir", _opts]) do
      {:ok,
       [
         %{"content" => "Elixir runs on the BEAM VM.", "source" => "docs/elixir.md"},
         %{"content" => "It was created by José Valim."}
       ]}
    end

    def call(:ingestion, _mod, :query_extraction, ["timeout query", _opts]) do
      {:error, :timeout}
    end

    def call(:ingestion, _mod, :query_extraction, [_query, _opts]) do
      {:ok, []}
    end
  end

  # Matches only when opts carry exactly person_id: 42, team_ids: [1, 2],
  # skip_permissions: false — any deviation causes the fallback to return an
  # error, which fails the test that asserts {:ok, _}.
  defmodule PermissionRouter do
    def call(:ingestion, _mod, :query_extraction, [
          _query,
          [person_id: 42, team_ids: [1, 2], skip_permissions: false]
        ]) do
      {:ok, []}
    end

    def call(:ingestion, _mod, :query_extraction, [_query, opts]) do
      {:error, {:unexpected_opts, opts}}
    end
  end

  defmodule SkipPermissionsRouter do
    def call(:ingestion, _mod, :query_extraction, [_query, opts]) do
      case {Keyword.get(opts, :person_id), Keyword.get(opts, :skip_permissions)} do
        {nil, true} -> {:ok, []}
        {_id, false} -> {:ok, []}
        {_id, other} -> {:error, {:skip_permissions_was, other}}
      end
    end
  end

  defmodule DefaultTeamIdsRouter do
    def call(:ingestion, _mod, :query_extraction, [_query, opts]) do
      case Keyword.get(opts, :team_ids) do
        [] -> {:ok, []}
        other -> {:error, {:team_ids_was, other}}
      end
    end
  end

  describe "run/2 — basic behaviour" do
    test "returns formatted chunks and count on success" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: StubNodeRouter}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "find elixir"}, context)
      assert result.count == 2
      assert String.contains?(result.chunks, "Elixir runs on the BEAM VM.")
      assert String.contains?(result.chunks, "Source: docs/elixir.md")
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
      assert result.chunks == ""
    end
  end

  describe "run/2 — permission enforcement" do
    test "allows BO users (nil person_id) with skip_permissions: true" do
      context = %{person_id: nil, node_router: SkipPermissionsRouter}

      assert {:ok, _} = SearchKnowledgeBase.run(%{query: "anything"}, context)
    end

    test "allows BO users when person_id is absent from context" do
      context = %{team_ids: [1], node_router: SkipPermissionsRouter}

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
