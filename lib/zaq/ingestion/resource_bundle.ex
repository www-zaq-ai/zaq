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
  whatever called across the boundary and, through a tool result, to a model. It is dropped
  when entries are minted into records by `Zaq.Ingestion.BundleRecords`, as is the resolved
  volume name.

  ## Listings are a record page

  `list/1` returns a `Zaq.Contracts.RecordPage` — the same contract the channel bridges and
  `Zaq.Ingestion.RecordSource` already return, rather than a shape invented for skills. Each
  record is identity and metadata plus a descriptor saying where the bytes live, so a caller
  hands one back to `Zaq.Records.Materializer` for content and never carries a locator
  alongside the file it belongs to.

  The three resource types are not separate keys. `record.path` already carries its type
  directory, so a per-type map would state the same fact twice and force every consumer to
  flatten it; the types survive as list order instead.

  ## Two levels of entry point, one module

  `materialize/1` is the record-shaped read: it takes a record minted by `list/1` and fills
  `content`. It reads the **bundle** off the descriptor and the **file** off `record.path` —
  the descriptor carries only the locator, because that is the one field that must never be
  serialized to a model, while the path is metadata a model is shown anyway. `read_text/2`,
  `read_bytes/2` and `stat/2` are the path-shaped reads underneath it, kept public because
  the BO and `Zaq.Agent.Skill.Resources` legitimately address files by path rather than by
  handle.

  These live together because minting a record and filling one are the same knowledge read in
  two directions — `list/1` writes the locator into a descriptor alongside a path, and
  `materialize/1` reads the pair back. Splitting them put the two halves of one mapping in two
  files and bought nothing: the module that returns records is not made cleaner by being
  unable to fill them.

  `record.path` being load-bearing does not weaken anything: it runs through
  `validate_resource_path/1` exactly as any caller-supplied path does, so a tampered path is
  refused rather than trusted. `materialize/1` refuses before touching disk: a descriptor
  carrying a `volume` key, and one missing a `locator` — or a record missing a path. A
  `volume` is **refused, not ignored** — a caller that sent one has misunderstood the
  contract, and dropping it silently teaches them the key works.

  ## Read-only, by omission

  There is no write function here, so no `Zaq.Ingestion.Api` clause can reach one, so nothing
  an agent sends can write to a volume. When a write verb is needed it arrives as its own
  function behind its own action — coarser than a declared capability list, and more visible.
  """

  require Logger

  alias Jido.AI.Skill.Resources, as: JidoResources
  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Ingestion.BundleRecords
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Records.Content

  @types [:references, :assets, :scripts]
  @type_dirs Enum.map(@types, &Atom.to_string/1)

  @type locator :: String.t()
  @type listing :: RecordPage.t()

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
      {:ok, {_volume, root}} ->
        {:ok, root |> JidoResources.list_resources() |> BundleRecords.from_listing(locator)}

      :not_found ->
        {:ok, BundleRecords.empty_page()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fills a bundle record's `content` from the file it names.

  The inverse of what `list/1` minted: the bundle comes back off the descriptor and the file
  off `record.path`, never off anything a caller said alongside the record. The path is
  validated here exactly as a path-shaped caller's would be, so a record whose `path` was
  tampered with reaches no more than a listed one could. Refuses a descriptor carrying a
  `volume` key, one missing a `locator`, and a record with no path — in each case without
  reading anything.
  """
  @spec materialize(Record.t()) :: {:ok, Record.t()} | {:error, term()}
  def materialize(%Record{materialization: %Materialization{params: params}})
      when is_map_key(params, :volume) or is_map_key(params, "volume"),
      do: {:error, :volume_not_addressable}

  def materialize(
        %Record{
          path: resource_path,
          materialization: %Materialization{
            params: %{locator: locator},
            as: as,
            max_bytes: max
          }
        } = record
      )
      when is_binary(locator) and is_binary(resource_path) do
    with :ok <- within_read_cap(locator, resource_path, max),
         {:ok, bytes} <- read(locator, resource_path, as) do
      Content.put(record, bytes, as)
    end
  end

  def materialize(%Record{}), do: {:error, :invalid_params}

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
  Stats one resource without reading it.

  The cheap half of a size check. Reading a multi-megabyte file in order to discover it is
  too large — and, once base64 is in play, inflating it by a third on the way — is waste a
  stat avoids entirely.
  """
  @spec stat(locator(), String.t()) ::
          {:ok, %{size: non_neg_integer(), modified: DateTime.t()}} | {:error, atom()}
  def stat(locator, resource_path) when is_binary(locator) and is_binary(resource_path) do
    with :ok <- validate_resource_path(resource_path),
         {:ok, {_volume, root}} <- locate_for_read(locator),
         {:ok, info} <- JidoResources.resource_info(root, resource_path) do
      {:ok, %{size: info.size, modified: info.modified}}
    end
  end

  @doc """
  Reads one resource as raw bytes.

  The counterpart to `read_text/2` for callers that can take binary content. Both go through
  Jido's `resolve_path/2`, so the containment and symlink guards are identical; the only
  difference is that this one does not require valid UTF-8.
  """
  @spec read_bytes(locator(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def read_bytes(locator, resource_path) when is_binary(locator) and is_binary(resource_path) do
    with :ok <- validate_resource_path(resource_path),
         {:ok, {_volume, root}} <- locate_for_read(locator) do
      JidoResources.load_resource(root, resource_path)
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

  # --- Descriptor-shaped reading ---

  # `:text` goes through `read_text/2` so Jido's own UTF-8 check produces the refusal, rather
  # than us reading bytes and second-guessing it.
  defp read(locator, resource_path, :text), do: read_text(locator, resource_path)
  defp read(locator, resource_path, _as), do: read_bytes(locator, resource_path)

  defp within_read_cap(_locator, _resource_path, nil), do: :ok

  defp within_read_cap(locator, resource_path, max) do
    case stat(locator, resource_path) do
      {:ok, %{size: size}} when size > max -> {:error, {:too_large, size}}
      {:ok, _info} -> :ok
      {:error, reason} -> {:error, reason}
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
      # `Path.split("")` is `[]`, so this has to come before anything reaching for a head.
      segments == [] -> {:error, :invalid_resource_path}
      Path.type(resource_path) == :absolute -> {:error, :path_traversal}
      ".." in segments -> {:error, :path_traversal}
      match?([_type], segments) -> {:error, :invalid_resource_path}
      hd(segments) not in @type_dirs -> {:error, :invalid_resource_path}
      true -> :ok
    end
  end
end
