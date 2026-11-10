defmodule Zaq.Agent.Tools.KnowledgeRetrievalPermissionsTest do
  @moduledoc """
  Exercises both knowledge tools through real NodeRouter/Ingestion and persisted
  permissions. Only the external embedding provider is stubbed.
  """
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{People, Team}
  alias Zaq.Agent.Tools.{GetKnowledgeBaseChunks, SearchKnowledgeBase}
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document, KnowledgeChunks}
  alias Zaq.Permissions
  alias Zaq.System.OperationModelConfig, as: RAGModelConfig
  alias Zaq.SystemConfigFixtures

  @dimension 1536

  setup do
    Chunk.create_table(@dimension)
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: @dimension})
    ChunkLanguages.invalidate()
    on_exit(fn -> ChunkLanguages.invalidate() end)

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, @dimension)}]})
      )
    end)

    {:ok, person} = People.create_person(%{full_name: "Knowledge reader"})

    team =
      %Team{}
      |> Team.changeset(%{name: "knowledge-#{Ecto.UUID.generate()}"})
      |> Repo.insert!()

    public = document_chunk("public")
    personal = document_chunk("personal")
    shared = document_chunk("team")
    private = document_chunk("private")
    {:ok, _} = Permissions.grant_public(public.document)
    {:ok, _} = Permissions.grant(personal.document, %{person_id: person.id})
    {:ok, _} = Permissions.grant(shared.document, %{team_id: team.id})

    %{
      person: person,
      team: team,
      fixtures: [public, personal, shared, private],
      context: %{
        context_window: %{max_context_tokens: 128_000},
        reranking_config: %RAGModelConfig{}
      }
    }
  end

  for mode <- ["semantic", "keyword", "hybrid"] do
    test "#{mode} and exact fetch enforce the same public, person and team grants", ctx do
      [public, personal, shared, _private] = ctx.fixtures

      for {access, allowed} <- [
            {%{}, [public]},
            {%{person_id: nil}, [public]},
            {%{person_id: ctx.person.id}, [public, personal]},
            {%{person_id: ctx.person.id, team_ids: [ctx.team.id]}, [public, personal, shared]},
            {%{skip_permissions: true}, ctx.fixtures}
          ] do
        context = Map.merge(ctx.context, access)
        assert {:ok, result} = search(unquote(mode), context)
        assert result.errors == []
        refute result.partial
        assert result.count == length(ctx.fixtures)
        assert accessible_ids(result.chunks) == fixture_ids(allowed)

        for denied <- Enum.reject(result.chunks, &is_integer(&1["chunk_id"])) do
          assert denied["content"] == KnowledgeChunks.access_denied_message()

          for key <- ~w(chunk_id previous_chunk_id next_chunk_id title metadata language) do
            refute Map.has_key?(denied, key)
          end
        end

        assert {:ok, fetched} = fetch(ctx.fixtures, context)
        assert accessible_ids(fetched.chunks) == fixture_ids(allowed)

        assert Enum.sort(fetched.unavailable_ids) ==
                 fixture_ids(ctx.fixtures -- allowed)
      end
    end

    test "#{mode} keeps source restrictions and rechecks a grant revoked after search", ctx do
      [public | _] = ctx.fixtures
      context = Map.put(ctx.context, :source_filter, [public.document.source])
      assert {:ok, result} = search(unquote(mode), context)
      assert accessible_ids(result.chunks) == [public.chunk.id]
      assert result.sources == [public.document.source]

      assert {:ok, fetched} = fetch(ctx.fixtures, context)
      assert accessible_ids(fetched.chunks) == [public.chunk.id]
      assert length(fetched.unavailable_ids) == 3

      :ok = Permissions.revoke_public(public.document)

      assert {:ok, %{chunks: [], unavailable_ids: [id]}} =
               Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: [public.chunk.id]}, context)

      assert id == public.chunk.id
    end

    test "#{mode} cannot gain access through untrusted parameters or truthy bypass", ctx do
      [public | _] = ctx.fixtures

      untrusted = %{
        person_id: ctx.person.id,
        team_ids: [ctx.team.id],
        skip_permissions: true,
        access_opts: [skip_permissions: true]
      }

      # Even direct invocation (without schema validation) must use trusted context.
      assert {:ok, result} =
               SearchKnowledgeBase.run(
                 Map.merge(search_params(unquote(mode)), untrusted),
                 ctx.context
               )

      assert accessible_ids(result.chunks) == [public.chunk.id]

      for bypass <- [nil, false, "true", 1, :admin] do
        context = Map.put(ctx.context, :skip_permissions, bypass)
        assert {:ok, result} = search(unquote(mode), context)
        assert accessible_ids(result.chunks) == [public.chunk.id]
      end

      assert {:ok, fetched} =
               GetKnowledgeBaseChunks.run(
                 Map.merge(%{chunk_ids: Enum.map(ctx.fixtures, & &1.chunk.id)}, untrusted),
                 ctx.context
               )

      assert accessible_ids(fetched.chunks) == [public.chunk.id]
    end
  end

  test "exact tool fetch does not distinguish denied, missing and deleted IDs", ctx do
    [public, _personal, _shared, private] = ctx.fixtures
    deleted = document_chunk("deleted")
    Repo.delete!(deleted.chunk)
    missing = deleted.chunk.id + 1
    ids = [private.chunk.id, missing, public.chunk.id, deleted.chunk.id]

    assert {:ok, result} =
             Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: ids}, ctx.context)

    assert accessible_ids(result.chunks) == [public.chunk.id]
    assert result.unavailable_ids == [private.chunk.id, missing, deleted.chunk.id]
    assert result.sources == [public.document.source]
    refute inspect(result) =~ private.chunk.content
  end

  property "exact fetch returns only the permitted subset in first-requested order", ctx do
    [public, personal, shared, private] = ctx.fixtures
    allowed_ids = MapSet.new([public.chunk.id, personal.chunk.id, shared.chunk.id])
    all_ids = [public.chunk.id, personal.chunk.id, shared.chunk.id, private.chunk.id]
    context = Map.merge(ctx.context, %{person_id: ctx.person.id, team_ids: [ctx.team.id]})

    check all(ids <- list_of(member_of(all_ids), min_length: 1, max_length: 16), max_runs: 20) do
      requested = Enum.uniq(ids)
      assert {:ok, result} = Jido.Exec.run(GetKnowledgeBaseChunks, %{chunk_ids: ids}, context)

      assert Enum.map(result.chunks, & &1["chunk_id"]) ==
               Enum.filter(requested, &MapSet.member?(allowed_ids, &1))

      assert result.unavailable_ids == Enum.reject(requested, &MapSet.member?(allowed_ids, &1))
      assert result.count == length(result.chunks)
    end
  end

  defp document_chunk(label) do
    {:ok, document} =
      Document.upsert(%{source: "permission-#{Ecto.UUID.generate()}/#{label}.md"})

    {:ok, chunk} =
      Chunk.create(%{
        document_id: document.id,
        chunk_index: 1,
        content: "permissionneedle #{label} evidence",
        section_path: ["Evidence"],
        language: "simple",
        embedding: List.duplicate(0.1, @dimension)
      })

    %{document: document, chunk: chunk}
  end

  defp search(mode, context),
    do: Jido.Exec.run(SearchKnowledgeBase, search_params(mode), context)

  defp search_params(mode),
    do: %{query: "permissionneedle", lexical_terms: ["permissionneedle"], search_mode: mode}

  defp fetch(fixtures, context),
    do:
      Jido.Exec.run(
        GetKnowledgeBaseChunks,
        %{chunk_ids: Enum.map(fixtures, & &1.chunk.id)},
        context
      )

  defp accessible_ids(chunks),
    do: chunks |> Enum.map(& &1["chunk_id"]) |> Enum.filter(&is_integer/1) |> Enum.sort()

  defp fixture_ids(fixtures), do: fixtures |> Enum.map(& &1.chunk.id) |> Enum.sort()
end
