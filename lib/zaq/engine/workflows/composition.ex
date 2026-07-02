defmodule Zaq.Engine.Workflows.Composition do
  @moduledoc """
  Workflow-in-workflow composition.

  A workflow node of `"type" => "workflow"` references another workflow by id
  (`params["workflow_ref"]`). `expand/2` splices the referenced workflow's nodes
  and edges *inline* into the parent snapshot, producing one flat DAG — one
  `WorkflowRun`, one `StepRun` stream, no child runs.

  The splice is pure over snapshots; the referenced workflow's snapshot is
  supplied by an injected `resolver` fun (`workflow_ref id -> {:ok, snapshot}`),
  so the core needs no database. `Workflows.create_run/4` passes a resolver that
  loads and serialises the referenced workflow at run-creation time — the
  reference is therefore resolved fresh per run and frozen into the persisted
  snapshot for that run's lifetime (edits to a referenced workflow never affect
  in-progress runs).

  Composition rules:

  - **Single entry/exit** — a referenced workflow must have exactly one root
    (entry) and one leaf (exit); the seam edge `X -> ref` is rewired to
    `X -> entry` and `ref -> Y` to `exit -> Y`.
  - **Namespacing** — inlined nodes are namespaced `"<ref_node_name>/<inner_name>"`
    so names stay unique (and a workflow may be referenced more than once).
  - **Acyclicity** — `validate/2` rejects reference cycles and any composition
    whose flattened graph is not acyclic.
  - **Seam mapping** — seam data mapping is passthrough: the existing edge
    `"mapping"` / `"condition"` on the seam edges is preserved unchanged.
  """

  @type snapshot :: %{required(String.t()) => list()}
  @type resolver :: (String.t() -> {:ok, snapshot} | {:error, term()})

  @doc """
  Flattens every `"type" => "workflow"` reference in `snapshot` inline.

  Returns `{:ok, flat_snapshot}`, or `{:error, reason}` where `reason` is
  `{:workflow_cycle, id}` (a reference loops back on itself) or
  `{:multi_entry_exit, roots, leaves}` (a referenced workflow violates the
  single root / single leaf rule).
  """
  @spec expand(snapshot, resolver) :: {:ok, snapshot} | {:error, term()}
  def expand(snapshot, resolver) do
    case expand(snapshot, resolver, MapSet.new()) do
      {:ok, flat} -> {:ok, reindex(flat)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `expand/2` but raises on error. Used at run-creation where an invalid
  composition should already have been rejected at save time by `validate/2`.
  """
  @spec expand!(snapshot, resolver) :: snapshot
  def expand!(snapshot, resolver) do
    case expand(snapshot, resolver) do
      {:ok, flat} -> flat
      {:error, reason} -> raise ArgumentError, "invalid workflow composition: #{inspect(reason)}"
    end
  end

  @doc """
  Validates that `snapshot` composes into a runnable DAG.

  Returns `:ok`, or `{:error, reason}` for a reference cycle
  (`{:workflow_cycle, id}`), a single-root/leaf violation
  (`{:multi_entry_exit, roots, leaves}`), or a flattened graph that is not
  acyclic (`{:workflow_not_acyclic, nodes}`). Intended to run at workflow save
  time, so a persisted workflow is always runnable.
  """
  @spec validate(snapshot, resolver) :: :ok | {:error, term()}
  def validate(snapshot, resolver) do
    with {:ok, flat} <- expand(snapshot, resolver) do
      if acyclic?(flat), do: :ok, else: {:error, {:workflow_not_acyclic, offending_nodes(flat)}}
    end
  end

  # ── expansion ───────────────────────────────────────────────────────────────

  defp expand(%{"nodes" => nodes, "edges" => edges}, resolver, seen) do
    # Process nodes in DAG (`index`) order so the spliced node list comes out
    # topologically ordered; `reindex/1` then renumbers it globally.
    nodes = Enum.sort_by(nodes, &(&1["index"] || 0))

    Enum.reduce_while(nodes, {:ok, %{"nodes" => [], "edges" => edges}}, fn
      %{"type" => "workflow"} = ref, {:ok, acc} ->
        case splice(acc, ref, resolver, seen) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, _} = err -> {:halt, err}
        end

      plain, {:ok, acc} ->
        {:cont, {:ok, update_in(acc["nodes"], &(&1 ++ [plain]))}}
    end)
  end

  defp splice(acc, %{"name" => rname, "params" => %{"workflow_ref" => id}}, resolver, seen) do
    if MapSet.member?(seen, id) do
      {:error, {:workflow_cycle, id}}
    else
      with {:ok, raw} <- resolver.(id),
           {:ok, sub} <- expand(raw, resolver, MapSet.put(seen, id)),
           {:ok, {entry, leaf}} <- entry_and_leaf(sub) do
        ns = &"#{rname}/#{&1}"
        sub_nodes = Enum.map(sub["nodes"], &Map.update!(&1, "name", ns))
        sub_edges = Enum.map(sub["edges"], &rename_edge(&1, ns))
        rewired = Enum.map(acc["edges"], &rewire_seam(&1, rname, ns.(entry), ns.(leaf)))
        {:ok, %{"nodes" => acc["nodes"] ++ sub_nodes, "edges" => rewired ++ sub_edges}}
      end
    end
  end

  # entry = the only node with no incoming edge; leaf = the only node with no
  # outgoing edge (the single-root / single-leaf constraint).
  defp entry_and_leaf(%{"nodes" => nodes, "edges" => edges}) do
    tos = MapSet.new(edges, & &1["to"])
    froms = MapSet.new(edges, & &1["from"])
    names = Enum.map(nodes, & &1["name"])
    roots = Enum.reject(names, &MapSet.member?(tos, &1))
    leaves = Enum.reject(names, &MapSet.member?(froms, &1))

    case {roots, leaves} do
      {[root], [leaf]} -> {:ok, {root, leaf}}
      _ -> {:error, {:multi_entry_exit, roots, leaves}}
    end
  end

  # Renumber every node's `index` to its position in the flattened (topologically
  # ordered) list, so `DagBuilder.assemble/4` (which sorts by `index`) wires
  # predecessors before successors.
  defp reindex(%{"nodes" => nodes} = snapshot) do
    renumbered = nodes |> Enum.with_index() |> Enum.map(fn {n, i} -> Map.put(n, "index", i) end)
    %{snapshot | "nodes" => renumbered}
  end

  defp rename_edge(edge, ns), do: edge |> Map.update!("from", ns) |> Map.update!("to", ns)

  # Rewire a parent edge touching the reference node onto the spliced seam.
  defp rewire_seam(%{"to" => rname} = edge, rname, entry, _leaf), do: %{edge | "to" => entry}
  defp rewire_seam(%{"from" => rname} = edge, rname, _entry, leaf), do: %{edge | "from" => leaf}
  defp rewire_seam(edge, _rname, _entry, _leaf), do: edge

  # ── acyclicity ──────────────────────────────────────────────────────────────

  defp acyclic?(flat) do
    graph = build_digraph(flat)

    try do
      :digraph_utils.is_acyclic(graph)
    after
      :digraph.delete(graph)
    end
  end

  defp offending_nodes(flat) do
    graph = build_digraph(flat)

    try do
      graph |> :digraph_utils.cyclic_strong_components() |> List.flatten()
    after
      :digraph.delete(graph)
    end
  end

  defp build_digraph(%{"nodes" => nodes, "edges" => edges}) do
    graph = :digraph.new()
    Enum.each(nodes, &:digraph.add_vertex(graph, &1["name"]))

    Enum.each(edges, fn %{"from" => from, "to" => to} ->
      :digraph.add_vertex(graph, from)
      :digraph.add_vertex(graph, to)
      :digraph.add_edge(graph, from, to)
    end)

    graph
  end
end
