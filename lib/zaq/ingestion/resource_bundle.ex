defmodule Zaq.Ingestion.ResourceBundle do
  @moduledoc """
  Reads Open Agent Skills resource bundles from ingestion volumes.

  This module is the **sole owner of locator → volume resolution**. It is the one place in
  the codebase that answers "which volume holds these files?", and the only place a volume
  name appears on the read path.

  ## What a bundle is

  A *bundle* is a directory laid out per the Open Agent Skills convention — `references/`,
  `assets/` and `scripts/` beneath a root. This module knows nothing beyond that: not what a
  skill is, not that ZAQ stores bundles under `.agents/skills/{slug}`. That convention lives
  in `Zaq.Agent.Skill.Resources` and stays there.

  ## The locator

  A `locator` is a **volume-relative** path to a bundle root, e.g.
  `.agents/skills/pricing-faq`. Callers hold it opaquely and hand it back unmodified; they
  never learn which volume it resolved against. Resolution walks the configured volumes in
  sorted order and takes the first that holds an existing directory — a local `File.dir?/1`
  per volume, on the node that owns the mounts, so it costs microseconds and no cross-node
  hops. When more than one volume matches, the sorted-first wins and the ambiguity is logged:
  deterministic beats arbitrary (`Map.keys/1` ordering is not guaranteed), and a duplicated
  bundle directory is something an operator needs told about.

  ## Two containment checks, on purpose

  `FileExplorer.resolve_path/2` guards the path against the **volume** root;
  `Jido.AI.Skill.Resources` guards it again against the **bundle** root, and additionally
  resolves symlinks. Different roots, so this is defence in depth rather than redundancy. On
  top of both, a bundle root reached through a symlink is refused outright — uploads never
  create one, so a symlinked root is not a configuration worth supporting.

  ## Nothing about the filesystem leaves this module

  Jido's entries carry `:absolute_path`. That discloses the ingestion node's layout to
  whatever called across the boundary and, through a tool result, to a model. It is stripped
  from every entry, as is the resolved volume name. Callers receive `:name`,
  `:resource_path`, `:size` and `:modified` — nothing else.
  """

  require Logger

  alias Jido.AI.Skill.Resources, as: JidoResources
  alias Zaq.Ingestion.FileExplorer

  @types [:references, :assets, :scripts]
  @type_dirs Enum.map(@types, &Atom.to_string/1)
  @empty_listing %{references: [], assets: [], scripts: []}

  @type locator :: String.t()
  @type entry :: %{
          name: String.t(),
          resource_path: String.t(),
          size: non_neg_integer(),
          modified: DateTime.t()
        }
  @type listing :: %{references: [entry()], assets: [entry()], scripts: [entry()]}

  @doc """
  Lists a bundle's resources, metadata only.

  A locator that no volume holds yields an **empty listing rather than an error** — a skill
  with nothing uploaded is an ordinary state, not a failure.

  Returns `{:error, :no_volumes}` when no volume is configured, and
  `{:error, :path_traversal}` for a locator that is absolute or escapes its volume.
  """
  @spec list(locator()) :: {:ok, listing()} | {:error, atom()}
  def list(locator) when is_binary(locator) do
    case locate(locator) do
      {:ok, {_volume, root}} -> {:ok, root |> JidoResources.list_resources() |> to_listing()}
      :not_found -> {:ok, @empty_listing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads one resource as UTF-8 text.

  `resource_path` is relative to the bundle root and **must** carry its type directory
  (`references/guide.md`, not `guide.md`) — a bare filename is refused rather than guessed
  at, because guessing would let a caller reach a file it did not name.

  Returns `{:error, :invalid_utf8}` for binary content, `{:error, :not_found}` for a missing
  bundle or file, and `{:error, :path_traversal}` for anything trying to escape.
  """
  @spec read_text(locator(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def read_text(locator, resource_path) when is_binary(locator) and is_binary(resource_path) do
    with :ok <- validate_resource_path(resource_path),
         {:ok, {_volume, root}} <- locate_for_read(locator) do
      JidoResources.load_resource_text(root, resource_path)
    end
  end

  @doc """
  The volume holding a bundle.

  Exported for the BO, which legitimately displays where a skill's files live. Agent-side
  callers must not use it — they address bundles by locator and have no business knowing a
  volume exists.
  """
  @spec resolve_volume(locator()) :: {:ok, String.t()} | :not_found | {:error, atom()}
  def resolve_volume(locator) when is_binary(locator) do
    case locate(locator) do
      {:ok, {volume, _root}} -> {:ok, volume}
      other -> other
    end
  end

  # --- Resolution ---

  defp locate_for_read(locator) do
    case locate(locator) do
      :not_found -> {:error, :not_found}
      other -> other
    end
  end

  defp locate(locator) do
    with :ok <- validate_locator(locator),
         :ok <- ensure_volumes() do
      case matching_bundles(locator) do
        [] -> :not_found
        [single] -> {:ok, single}
        [first | _] = all -> {:ok, warn_ambiguous(locator, all, first)}
      end
    end
  end

  defp ensure_volumes do
    if FileExplorer.volumes_configured?(), do: :ok, else: {:error, :no_volumes}
  end

  # Sorted so the winner never depends on `Map.keys/1` ordering.
  defp matching_bundles(locator) do
    volumes = FileExplorer.list_volumes()

    volumes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn volume ->
      case bundle_root(volumes, volume, locator) do
        {:ok, root} -> [{volume, root}]
        :error -> []
      end
    end)
  end

  defp bundle_root(volumes, volume, locator) do
    with {:ok, volume_root} <- Map.fetch(volumes, volume),
         {:ok, absolute} <- FileExplorer.resolve_path(volume, locator),
         true <- File.dir?(absolute),
         true <- symlink_free?(volume_root, absolute) do
      {:ok, absolute}
    else
      _ -> :error
    end
  end

  # A bundle root reached through a symlink is refused. Jido guards symlinks *within* a
  # bundle, but it takes the root it is given as authoritative — so a symlinked root would
  # silently relocate the whole containment check outside the volume.
  defp symlink_free?(volume_root, absolute) do
    absolute
    |> Path.relative_to(volume_root)
    |> Path.split()
    |> Enum.reduce_while({volume_root, true}, fn segment, {current, _ok} ->
      candidate = Path.join(current, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {candidate, false}}
        _ -> {:cont, {candidate, true}}
      end
    end)
    |> elem(1)
  end

  defp warn_ambiguous(locator, all, {volume, _root} = winner) do
    Logger.warning(
      "[ResourceBundle] #{inspect(locator)} resolves on more than one volume " <>
        "(#{Enum.map_join(all, ", ", &elem(&1, 0))}); using #{inspect(volume)}. " <>
        "A duplicated bundle directory should be removed."
    )

    winner
  end

  # --- Validation ---

  # The locator is untrusted even though it is ZAQ-derived: it round-trips through another
  # node, and a shape guard here is cheaper than reasoning about every caller.
  defp validate_locator(locator) do
    segments = Path.split(locator)

    cond do
      String.trim(locator) == "" -> {:error, :path_traversal}
      Path.type(locator) == :absolute -> {:error, :path_traversal}
      ".." in segments -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp validate_resource_path(resource_path) do
    segments = Path.split(resource_path)

    cond do
      Path.type(resource_path) == :absolute -> {:error, :path_traversal}
      ".." in segments -> {:error, :path_traversal}
      match?([_type], segments) -> {:error, :invalid_resource_path}
      hd(segments) not in @type_dirs -> {:error, :invalid_resource_path}
      true -> :ok
    end
  end

  # --- Shaping ---

  defp to_listing(jido_listing) do
    Map.new(@types, fn type ->
      {type, jido_listing |> Map.get(type, []) |> Enum.map(&to_entry/1)}
    end)
  end

  defp to_entry(%{name: name, relative_path: relative_path, size: size, modified: modified}) do
    %{name: name, resource_path: relative_path, size: size, modified: modified}
  end
end
