defmodule Zaq.Ingestion.Records.SkillBundleStrategy do
  @moduledoc """
  Materializes and persists files inside an Open Agent Skills bundle on an ingestion volume.

  The first `Zaq.Records.Strategy`, and the shape every later one should follow: it is thin.
  All it does is check its own params, apply the caller's acceptance rules, and delegate to
  `Zaq.Ingestion.ResourceBundle`, which remains the sole owner of locator→volume resolution
  and of both containment guards. A strategy that started resolving paths itself would be
  duplicating the one piece of this system most worth having in a single place.

  ## `params`

    * `locator` — the bundle root, volume-relative. Required for both verbs.
    * `resource_path` — the file, bundle-relative and type-prefixed. Required to materialize.
    * `purpose` — `:reference` or `:asset`, required to persist. It names *intent*; this
      module maps it to a directory. A caller cannot supply a destination path, because a
      caller that could choose where it writes could write outside what it was granted.

  A `volume` key is **refused, not ignored**. A caller that sent one has misunderstood the
  contract, and silently dropping it teaches them the key works.

  ## Reading

  `max_bytes` is checked with a stat before anything is read. That ordering matters more
  than it looks: base64 inflates by 4/3, so reading a 5 MiB image — a legitimate upload
  under `resource_max_bytes` — in order to ship 6.7 MiB across a node boundary and have the
  caller reject it is pure waste.

  Encoding follows the caller's `as`: `:text` refuses non-UTF-8, `:binary` always encodes,
  `:auto` detects. `Zaq.Records.Content` does the work so this module does not invent a
  second encoding convention.

  ## Writing

  Bytes go in at their final destination — there is no staging file, so nothing needs
  cleaning up. Part 1's `resource_max_bytes` and `resource_max_files` still apply: they are
  the *upload* ceilings, deliberately looser than the read cap, and an agent writing a file
  is an upload like any other. A name collision is deduped rather than overwritten, and
  because the deduped name is what exists on disk, that is the name the returned handle
  carries.

  The returned record has `content: nil`. It is a handle, and handing back the bytes that
  were just sent would double the payload for no reason — the caller already has them.
  """

  @behaviour Zaq.Records.Strategy

  alias Zaq.Agent.Skills.Limits
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.BundleRecords
  alias Zaq.Ingestion.ResourceBundle
  alias Zaq.Records.Content

  @purpose_dirs %{reference: "references", asset: "assets"}

  @impl true
  def capabilities, do: [:materialize, :persist]

  @impl true
  def validate_params(%{volume: _}), do: {:error, :volume_not_addressable}
  def validate_params(%{"volume" => _}), do: {:error, :volume_not_addressable}

  def validate_params(%{locator: locator, resource_path: path})
      when is_binary(locator) and is_binary(path),
      do: :ok

  def validate_params(%{locator: locator, purpose: purpose})
      when is_binary(locator) and is_map_key(@purpose_dirs, purpose),
      do: :ok

  def validate_params(_params), do: {:error, :invalid_params}

  @impl true
  def materialize(
        %Record{materialization: %{params: params, as: as, max_bytes: max}} = record,
        _opts
      ) do
    %{locator: locator, resource_path: resource_path} = params

    with :ok <- within_read_cap(locator, resource_path, max),
         {:ok, bytes} <- read(locator, resource_path, as) do
      Content.put(record, bytes, as)
    end
  end

  @impl true
  def persist(%Record{materialization: %{params: params}} = record, _opts) do
    %{locator: locator, purpose: purpose} = params

    with {:ok, bytes} <- Content.decode(record),
         :ok <- within_upload_caps(locator, bytes),
         {:ok, resource_path} <- write(locator, purpose, record.name, bytes) do
      {:ok, handle(record, locator, resource_path, byte_size(bytes))}
    end
  end

  # --- Reading ---

  # `:text` goes through `read_text/2` so Jido's own UTF-8 check produces the refusal, rather
  # than us reading bytes and second-guessing it.
  defp read(locator, resource_path, :text), do: ResourceBundle.read_text(locator, resource_path)
  defp read(locator, resource_path, _as), do: ResourceBundle.read_bytes(locator, resource_path)

  defp within_read_cap(_locator, _resource_path, nil), do: :ok

  defp within_read_cap(locator, resource_path, max) do
    case ResourceBundle.stat(locator, resource_path) do
      {:ok, %{size: size}} when size > max -> {:error, {:too_large, size}}
      {:ok, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Writing ---

  defp within_upload_caps(locator, bytes) do
    max_bytes = Limits.get(:resource_max_bytes)
    max_files = Limits.get(:resource_max_files)

    cond do
      byte_size(bytes) > max_bytes -> {:error, {:too_large, byte_size(bytes)}}
      bundle_file_count(locator) >= max_files -> {:error, {:too_many_files, max_files}}
      true -> :ok
    end
  end

  defp bundle_file_count(locator) do
    case ResourceBundle.list(locator) do
      {:ok, listing} -> listing |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      _error -> 0
    end
  end

  defp write(locator, purpose, name, bytes) do
    with {:ok, filename} <- safe_filename(name) do
      ResourceBundle.write(locator, Path.join(@purpose_dirs[purpose], filename), bytes)
    end
  end

  # The name rides in on the record and is therefore caller-supplied. Only its basename is
  # kept, so a name carrying directory separators cannot steer the write.
  defp safe_filename(name) when is_binary(name) do
    case Path.basename(name) do
      basename when basename in ["", ".", ".."] -> {:error, :invalid_name}
      basename -> {:ok, basename}
    end
  end

  defp safe_filename(_name), do: {:error, :invalid_name}

  # The handle points at where the bytes actually landed — which may not be where they were
  # aimed, since a collision is deduped. `content: nil` because the caller already has them.
  defp handle(%Record{} = record, locator, resource_path, size) do
    %Record{
      record
      | id: BundleRecords.record_id(locator, resource_path),
        kind: :file,
        name: Path.basename(resource_path),
        path: resource_path,
        size: size,
        content: nil,
        attributes:
          record.attributes
          |> Map.drop(["encoding", :encoding])
          |> Map.merge(%{"provider" => "zaq_skill_bundle", "resource_path" => resource_path}),
        materialization: BundleRecords.descriptor(locator, resource_path)
    }
  end
end
