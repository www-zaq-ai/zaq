defmodule Zaq.Ingestion.DocumentAccess do
  @moduledoc """
  Permission-filtered document queries.

  Single responsibility: given a caller's identity (person_id + team_ids),
  determine which documents they can access and return counts or listings.

  Permission model:
  - Documents with no permission rows → not accessible to regular users (admin-only via `skip_permissions`).
  - Documents granted to the system Everyone team → accessible to all.
  - Documents with explicit permission rows → accessible only to matched persons/teams.
  - `skip_permissions: true` → all documents, used for admin/internal callers.

  `nil person_id` is never an implicit permission grant. Both nil and authenticated
  callers require an Everyone grant or a matching permission row. Documents with no
  permission rows are private — only `skip_permissions: true` (BO admin) can access them.
  """

  alias Zaq.Ingestion.{Chunk, Document}
  alias Zaq.Permissions.DocumentPermission, as: Permission
  alias Zaq.Repo

  import Ecto.Query

  @doc """
  Returns the subset of `doc_ids` the caller is permitted to access.

  A document is included if:
  - A permission row exists matching `person_id` or any of `team_ids`, including Everyone.

  Documents with no permission rows are not returned. This function is designed
  for filtering a known set of doc_ids fetched from an external source (e.g.,
  vector search results).
  """
  @spec list_permitted_document_ids(term(), [term()], [term()]) :: [term()]
  def list_permitted_document_ids(person_id, team_ids, doc_ids) do
    Permission.build_permission_query(person_id, team_ids, doc_ids)
    |> Repo.all()
  end

  @doc """
  Counts documents the caller is permitted to access.

  Options:
  - `:person_id` — ID of the requesting person.
  - `:team_ids` — list of team IDs the person belongs to (default `[]`).
  - `:skip_permissions` — when `true`, counts all documents.
  - `:source_filter` — list of source prefixes to restrict results. Files are
    matched exactly; folders are matched by prefix (`source LIKE "prefix/%"`).
    `nil` or `[]` means no filter (all sources).

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
        where: ^source_cond
      )
      |> Repo.aggregate(:count, :id)
    else
      accessible = build_accessible_where(person_id, team_ids)

      from(d in Document,
        as: :doc,
        left_join: p in Permission,
        on: p.resource_type == "document" and p.resource_id == fragment("?::text", d.id),
        as: :perm,
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
        on: p.resource_type == "document" and p.resource_id == fragment("?::text", d.id),
        as: :perm,
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
  # Both nil and authenticated person_id require an Everyone grant or a matching
  # permission row. Only skip_permissions: true (BO admin) bypasses this.
  defp build_accessible_where(nil, team_ids) do
    perm_cond = Permission.build_perm_join_condition(nil, team_ids)

    dynamic(
      [doc: d, perm: p],
      ^perm_cond
    )
  end

  defp build_accessible_where(person_id, team_ids) do
    perm_cond = Permission.build_perm_join_condition(person_id, team_ids)

    dynamic(
      [doc: d, perm: p],
      ^perm_cond
    )
  end

  @doc """
  Returns accessible indexed documents, each tagged `ingested: true/false`.

  Mounted files that have not been ingested are Storage/data-source browsing
  concerns and are not discovered by Ingestion.

  Accepts the same `opts` as `list_accessible_documents/1`.
  """
  def list_files_with_ingestion_status(opts \\ []) do
    ingested_set = list_ingested_source_set()

    opts
    |> list_accessible_documents()
    |> Enum.map(&Map.put(&1, :ingested, MapSet.member?(ingested_set, &1.source)))
  end

  defp list_ingested_source_set do
    from(d in Document,
      join: _c in Chunk,
      on: _c.document_id == d.id,
      select: d.source,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
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
