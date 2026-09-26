defmodule Zaq.Agent.Tools.SearchKnowledgeBaseTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Event
  alias Zaq.TestSupport.OpenAIStub

  defmodule StubNodeRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(%Event{request: %{query: "find elixir"}} = event) do
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

    def dispatch(%Event{request: %{query: "timeout query"}} = event),
      do: %{event | response: {:error, :timeout}}

    def dispatch(%Event{request: %{query: _query}} = event),
      do: %{event | response: {:ok, []}}
  end

  defmodule RaisingNodeRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{query: _query}}) do
      raise "router crashed"
    end
  end

  # Matches only when opts carry exactly person_id: 42, team_ids: [1, 2],
  # skip_permissions: false — any deviation causes the fallback to return an
  # error, which fails the test that asserts {:ok, _}.
  defmodule PermissionRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(
          %Event{
            request: %{
              query: _query,
              access_opts: [
                person_id: 42,
                team_ids: [1, 2],
                skip_permissions: false,
                language: "simple",
                unbounded: true,
                lexical_terms: ["test"]
              ]
            }
          } = event
        ) do
      %{event | response: {:ok, []}}
    end

    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      %{event | response: {:error, {:unexpected_opts, opts}}}
    end
  end

  defmodule SkipPermissionsRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(%Event{request: %{access_opts: opts}} = event) do
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
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      response =
        case Keyword.get(opts, :team_ids) do
          [] -> {:ok, []}
          other -> {:error, {:team_ids_was, other}}
        end

      %{event | response: response}
    end
  end

  defmodule LongTermsRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      expected = Enum.map(1..9, &"term#{&1}") ++ ["Saint-Saturnin"]

      if Keyword.fetch!(opts, :lexical_terms) == expected,
        do: %{event | response: {:ok, []}},
        else: %{event | response: {:error, :truncated_or_rewritten}}
    end
  end

  defmodule FrenchGeneration do
    def generate_text(_spec, _messages, _opts),
      do:
        response(
          ~s({"french":{"semantic_query":"voiture rouge","lexical_terms":["voiture","rouge"]}})
        )

    def response(text) do
      {:ok,
       %ReqLLM.Response{
         id: "test-translation",
         model: "test-model",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant(text)
       }}
    end
  end

  defmodule MissingTranslationGeneration do
    def generate_text(_spec, _messages, _opts), do: FrenchGeneration.response("{}")
  end

  defp translation_context(router, generator) do
    %{
      node_router: router,
      generation: generator,
      llm_config: OpenAIStub.llm_config("http://example.test/v1") |> Map.new(),
      skip_permissions: true
    }
  end

  defmodule MultilingualRouter do
    def dispatch(%Event{request: request} = event) when map_size(request) == 0,
      do: %{event | response: {:ok, ["simple", "french"]}}

    def dispatch(%Event{request: %{chunks: chunks}} = event),
      do: %{event | response: {:ok, chunks}}

    def dispatch(%Event{request: %{query: query, access_opts: opts}} = event) do
      response =
        case {Keyword.fetch!(opts, :language), query} do
          {"french", "voiture rouge"} ->
            {:ok,
             [
               %{
                 "document_id" => 2,
                 "chunk_index" => 1,
                 "distance" => 0.03,
                 "language" => "french",
                 "content" => "voiture rouge"
               }
             ]}

          {"simple", _} ->
            {:ok,
             [
               %{
                 "document_id" => 1,
                 "chunk_index" => 1,
                 "distance" => 0.02,
                 "language" => "simple",
                 "content" => "red car"
               }
             ]}

          _ ->
            {:error, :unexpected_query}
        end

      %{event | response: response}
    end
  end

  defmodule PartialRouter do
    def dispatch(%Event{request: %{query: _query, access_opts: opts}} = event) do
      if Keyword.get(opts, :language) == "french",
        do: %{event | response: {:error, :timeout}},
        else: MultilingualRouter.dispatch(event)
    end

    def dispatch(event), do: MultilingualRouter.dispatch(event)
  end

  describe "multilingual search" do
    test "translates once, searches each language and sorts by existing fused score" do
      assert {:ok, %{chunks: [french, simple], count: 2, partial: false, errors: []}} =
               SearchKnowledgeBase.run(
                 %{query: "red car", lexical_terms: ["red", "car"]},
                 translation_context(MultilingualRouter, FrenchGeneration)
               )

      assert french["language"] == "french"
      assert simple["language"] == "simple"
    end

    test "keeps successful results alongside a per-language failure" do
      assert {:ok,
              %{chunks: [simple], partial: true, errors: [%{language: "french", stage: :search}]}} =
               SearchKnowledgeBase.run(
                 %{query: "red car", lexical_terms: ["red", "car"]},
                 translation_context(PartialRouter, FrenchGeneration)
               )

      assert simple["language"] == "simple"
    end

    test "never silently retries an untranslated language; retains simple results" do
      assert {:ok,
              %{
                chunks: [simple],
                partial: true,
                errors: [%{language: "french", stage: :translation}]
              }} =
               SearchKnowledgeBase.run(
                 %{query: "red car", lexical_terms: ["red", "car"]},
                 translation_context(MultilingualRouter, MissingTranslationGeneration)
               )

      assert simple["language"] == "simple"
    end

    test "Zoi rejects non-string search input through validated Action execution" do
      for input <- [
            %{query: 3, lexical_terms: ["car"]},
            %{query: "car"},
            %{query: "car", lexical_terms: [3]}
          ] do
        assert {:error, _} =
                 Jido.Exec.run(SearchKnowledgeBase, input, %{node_router: StubNodeRouter})
      end
    end

    test "Zoi validates structured partial-result output through Action execution" do
      assert {:ok, %{partial: true, errors: [%{language: "french"}]}} =
               Jido.Exec.run(
                 SearchKnowledgeBase,
                 %{query: "red car", lexical_terms: ["red", "car"]},
                 translation_context(PartialRouter, FrenchGeneration)
               )
    end
  end

  describe "run/2 — basic behaviour" do
    test "simple uses all supplied terms including the name after eight other terms" do
      terms = Enum.map(1..9, &"term#{&1}") ++ ["Saint-Saturnin"]

      assert {:ok, %{chunks: []}} =
               SearchKnowledgeBase.run(
                 %{query: "Where is Saint-Saturnin?", lexical_terms: terms},
                 %{node_router: LongTermsRouter}
               )
    end

    test "returns formatted chunks and count on success" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: StubNodeRouter}

      assert {:ok, result} =
               SearchKnowledgeBase.run(%{query: "find elixir", lexical_terms: ["test"]}, context)

      assert result.count == 2

      [first_chunk | _] = result.chunks
      assert String.contains?(first_chunk["content"], "Elixir runs on the BEAM VM.")
      assert String.contains?(first_chunk["source"], "docs/elixir.md")
    end

    test "returns error message when NodeRouter returns error" do
      context = %{person_id: 42, node_router: StubNodeRouter}

      assert {:error, message} =
               SearchKnowledgeBase.run(
                 %{query: "timeout query", lexical_terms: ["test"]},
                 context
               )

      assert message =~ "Knowledge base search failed for all languages"
    end

    test "returns wrapped error when node router raises exception" do
      context = %{person_id: 42, node_router: RaisingNodeRouter}

      assert {:error, message} =
               SearchKnowledgeBase.run(%{query: "any query", lexical_terms: ["test"]}, context)

      assert message =~ "Knowledge base search failed for all languages"
      refute message =~ "router crashed"
    end

    test "returns empty chunks when no results found" do
      context = %{person_id: 42, node_router: StubNodeRouter}

      assert {:ok, result} =
               SearchKnowledgeBase.run(%{query: "nothing here", lexical_terms: ["test"]}, context)

      assert result.count == 0
      assert result.chunks == []
    end
  end

  describe "run/2 — permission enforcement" do
    test "nil person_id without skip_permissions passes skip_permissions: false (public data only)" do
      context = %{person_id: nil, node_router: SkipPermissionsRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "anything", lexical_terms: ["test"]}, context)
    end

    test "nil person_id absent from context also passes skip_permissions: false" do
      context = %{team_ids: [1], node_router: SkipPermissionsRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "anything", lexical_terms: ["test"]}, context)
    end

    test "nil person_id with explicit skip_permissions: true passes skip_permissions: true (admin)" do
      context = %{person_id: nil, skip_permissions: true, node_router: SkipPermissionsRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "anything", lexical_terms: ["test"]}, context)
    end

    test "forwards person_id and team_ids to query_extraction" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: PermissionRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "test", lexical_terms: ["test"]}, context)
    end

    test "sets skip_permissions: false when person_id is present" do
      context = %{person_id: 1, team_ids: [], node_router: SkipPermissionsRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "test", lexical_terms: ["test"]}, context)
    end

    test "defaults team_ids to [] when absent from context" do
      context = %{person_id: 1, node_router: DefaultTeamIdsRouter}

      assert {:ok, _} =
               SearchKnowledgeBase.run(%{query: "test", lexical_terms: ["test"]}, context)
    end

    test "forwards the actual team_ids value, not a hardcoded default" do
      # PermissionRouter only matches team_ids: [1, 2] — passing [99] must fail,
      # proving the value comes from context and not a hardcoded fallback.
      context = %{person_id: 42, team_ids: [99], node_router: PermissionRouter}

      assert {:error, _} =
               SearchKnowledgeBase.run(%{query: "test", lexical_terms: ["test"]}, context)
    end
  end
end
