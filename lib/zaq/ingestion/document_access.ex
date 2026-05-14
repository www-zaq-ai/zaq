defmodule Zaq.Ingestion.DocumentAccess do
  @moduledoc """
  Permission-filtered document queries.

  Single responsibility: given a caller's identity (person_id + team_ids),
  determine which documents they can access and return counts or listings.

  Permission model:
  - Documents with no permission rows → not accessible to regular users (admin-only via `skip_permissions`).
  - Documents tagged `"public"` → accessible to all.
  - Documents with explicit permission rows → accessible only to matched persons/teams.
  - `skip_permissions: true` → all documents, used for admin/internal callers.

  `nil person_id` is never an implicit permission grant. Without
  `skip_permissions: true`, a nil person_id returns only public-tagged documents
  and documents with team-matched permissions (if team_ids are provided).
  """

  alias Zaq.Ingestion.{Document, FileExplorer, Permission, Sidecar, SourcePath}
  alias Zaq.Repo

  import Ecto.Query

  @doc """
  Returns the subset of `doc_ids` the caller is permitted to access.

  A document is included if:
  - A permission row exists matching `person_id` or any of `team_ids`, OR
  - The document is tagged `"public"`.

  Note: documents with *no* permission rows at all are NOT returned here —
  use `count_accessible_documents/1` or `list_accessible_documents/1` when
  you need the "public by default" (no-permissions) behaviour for a full scan.
  This function is designed for filtering a known set of doc_ids fetched from
  an external source (e.g., vector search results).
  """
  @spec list_permitted_document_ids(term(), [term()], [term()]) :: [term()]
  def list_permitted_document_ids(person_id, team_ids, doc_ids) do
    via_permission =
      Permission.build_permission_query(person_id, team_ids, doc_ids)
      |> Repo.all()

    via_public =
      from(d in Document,
        where: d.id in ^doc_ids and fragment("? @> ARRAY[?]::varchar[]", d.tags, "public"),
        select: d.id
      )
      |> Repo.all()

    Enum.uniq(via_permission ++ via_public)
  end

  @doc """
  Counts documents the caller is permitted to access.

  Unlike `list_permitted_document_ids/3`, documents with no permission rows at
  all are treated as public (accessible to everyone).

  Options:
  - `:person_id` — ID of the requesting person.
  - `:team_ids` — list of team IDs the person belongs to (default `[]`).
  - `:skip_permissions` — when `true`, counts all documents.
  - `:source_filter` — list of source prefixes to restrict results. Files are
    matched exactly; folders are matched by prefix (`source LIKE "prefix/%"`).
    `nil` or `[]` means no filter (all sources).

  Chunks (documents whose metadata contains `source_document_source`) are excluded.
  """
  @spec count_accessible_documents(keyword()) :: non_neg_integer()
  def count_accessible_documents(opts \\ []) do
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])
    skip_permissions = Keyword.get(opts, :skip_permissions, false)
    source_filter = Keyword.get(opts, :source_filter)

    source_cond = build_source_filter_condition(source_filter)

    if skip_permissions do
      from(d in Document,
        as: :doc,
        where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
        where: ^source_cond
      )
      |> Repo.aggregate(:count, :id)
    else
      accessible = build_accessible_where(person_id, team_ids)

      from(d in Document,
        as: :doc,
        left_join: p in Permission,
        on: p.document_id == d.id,
        as: :perm,
        where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
        where: ^accessible,
        where: ^source_cond,
        select: count(d.id, :distinct)
      )
      |> Repo.one!()
    end
  end

  @doc """
  Lists documents the caller is permitted to access.

  Applies the same permission model as `count_accessible_documents/1`.
  Accepts the same options including `:source_filter`.
  Returns a list of `%{source: String.t(), title: String.t() | nil}` sorted
  by source path.
  """
  @spec list_accessible_documents(keyword()) :: [%{source: String.t(), title: String.t() | nil}]
  def list_accessible_documents(opts \\ []) do
    person_id = Keyword.get(opts, :person_id)
    team_ids = Keyword.get(opts, :team_ids, [])
    skip_permissions = Keyword.get(opts, :skip_permissions, false)
    source_filter = Keyword.get(opts, :source_filter)

    source_cond = build_source_filter_condition(source_filter)

    if skip_permissions do
      from(d in Document,
        as: :doc,
        where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
        where: ^source_cond,
        select: %{source: d.source, title: d.title},
        order_by: [asc: d.source]
      )
      |> Repo.all()
    else
      accessible = build_accessible_where(person_id, team_ids)

      from(d in Document,
        as: :doc,
        left_join: p in Permission,
        on: p.document_id == d.id,
        as: :perm,
        where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
        where: ^accessible,
        where: ^source_cond,
        select: %{source: d.source, title: d.title},
        distinct: true,
        order_by: [asc: d.source]
      )
      |> Repo.all()
    end
  end

  # All three access conditions unified in one named-binding dynamic to avoid
  # mixing positional and named bindings in the same where expression.
  #
  # nil person_id: returns only public-tagged docs and team-permission-matched docs.
  # authenticated person_id: same — docs with no permission rows are NOT accessible.
  defp build_accessible_where(nil, team_ids) do
    perm_cond = Permission.build_perm_join_condition(nil, team_ids)

    dynamic(
      [doc: d, perm: p],
      fragment("? @> ARRAY['public']::varchar[]", d.tags) or
        ^perm_cond
    )
  end

  defp build_accessible_where(person_id, team_ids) do
    perm_cond = Permission.build_perm_join_condition(person_id, team_ids)

    dynamic(
      [doc: d, perm: p],
      fragment("? @> ARRAY['public']::varchar[]", d.tags) or
        ^perm_cond
    )
  end

  @doc """
  Returns all files visible to the caller, each tagged `ingested: true/false`.

  For `skip_permissions: true` callers, the filesystem is walked recursively
  and cross-referenced against the DB — every file on disk appears in the
  result.  Ingested files carry `ingested: true` plus a `title`; unindexed
  files carry `ingested: false`.

  For permission-scoped callers, only accessible ingested documents are
  returned (unindexed files have no permission record to check against), each
  tagged `ingested: true`.

  Accepts the same `opts` as `list_accessible_documents/1`.
  """
  def list_files_with_ingestion_status(opts \\ []) do
    skip_permissions = Keyword.get(opts, :skip_permissions, false)
    source_filter = Keyword.get(opts, :source_filter)

    ingested_docs = list_accessible_documents(opts)

    if skip_permissions do
      ingested_map = Map.new(ingested_docs, fn doc -> {doc.source, doc} end)

      walk_file_sources(source_filter)
      |> Enum.map(&tag_ingestion_status(&1, ingested_map))
    else
      Enum.map(ingested_docs, &Map.put(&1, :ingested, true))
    end
  end

  defp walk_file_sources(source_filter) do
    volumes = FileExplorer.list_volumes()

    roots =
      if map_size(volumes) > 0 do
        Enum.map(volumes, fn {_name, root} -> root end)
      else
        [FileExplorer.base_path()]
      end

    roots
    |> Enum.flat_map(&list_files_recursive/1)
    |> Enum.map(&abs_path_to_source/1)
    |> Enum.reject(&is_nil/1)
    |> reject_sidecar_sources()
    |> filter_by_source_filter(source_filter)
  end

  defp reject_sidecar_sources(sources) do
    sidecar_set =
      sources
      |> Enum.map(&Sidecar.sidecar_path_for/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(sources, &MapSet.member?(sidecar_set, &1))
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &expand_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp expand_entry(dir, entry) do
    full_path = Path.join(dir, entry)
    if File.dir?(full_path), do: list_files_recursive(full_path), else: [full_path]
  end

  defp filter_by_source_filter(sources, nil), do: sources
  defp filter_by_source_filter(sources, []), do: sources

  defp filter_by_source_filter(sources, source_filter) do
    Enum.filter(sources, fn source ->
      Enum.any?(source_filter, &source_matches_prefix?(source, &1))
    end)
  end

  defp source_matches_prefix?(source, prefix) do
    if String.contains?(Path.basename(prefix), ".") do
      source == prefix
    else
      String.starts_with?(source, prefix <> "/")
    end
  end

  defp tag_ingestion_status(source, ingested_map) do
    case Map.get(ingested_map, source) do
      nil -> %{source: source, ingested: false}
      doc -> Map.put(doc, :ingested, true)
    end
  end

  defp abs_path_to_source(abs_path) do
    case SourcePath.absolute_to_source(abs_path) do
      {:ok, source} -> source
      _ -> nil
    end
  end

  @doc """
  Builds a named-binding dynamic WHERE condition for `source_filter`.

  Requires the query to have a `Document` binding named `:doc`.
  Files (last path segment contains `.`) are matched exactly; folders and
  connectors are matched by prefix (`source LIKE "prefix/%"`).
  `nil` or `[]` returns `true` (no filtering).
  """
  @spec build_source_filter_condition([String.t()] | nil) :: Ecto.Query.dynamic_expr()
  def build_source_filter_condition(nil), do: dynamic([doc: _d], true)
  def build_source_filter_condition([]), do: dynamic([doc: _d], true)

  def build_source_filter_condition(source_filter) do
    Enum.reduce(source_filter, dynamic([doc: _d], false), fn prefix, acc ->
      if String.contains?(prefix |> String.split("/") |> List.last(), ".") do
        dynamic([doc: d], ^acc or d.source == ^prefix)
      else
        dynamic([doc: d], ^acc or like(d.source, ^"#{prefix}/%"))
      end
    end)
  end
end
