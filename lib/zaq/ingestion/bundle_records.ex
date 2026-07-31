defmodule Zaq.Ingestion.BundleRecords do
  @moduledoc """
  Turns Open Agent Skills bundle entries into canonical `Zaq.Contracts.Record` handles.

  The bundle-scoped sibling of `Zaq.Ingestion.VolumeRecords`, and deliberately **not** built
  on it: `VolumeRecords` stamps `"volume"` into a record's attributes, which is exactly what
  a bundle record must never carry. A skill addresses its files by locator and has no
  business learning that volumes exist.

  ## What survives minting, and what does not

  Jido's listing entries carry `:absolute_path`. That discloses the ingestion node's
  filesystem layout to whatever called across the boundary and, through a tool result, to a
  model. It is dropped here along with any trace of the resolved volume. What remains is what
  a consumer legitimately needs to choose a file: `name`, `path` (the bundle-relative
  `resource_path`), `size`, `modified_at` and an inferred `mime_type`.

  ## The id is opaque, on purpose

  `:id` **is** in `Record`'s `Jason.Encoder` derive list. An id built by interpolating the
  locator — the obvious `"zaq_skill_bundle:{locator}:{resource_path}"` — would render the
  locator into every encoded record and quietly undo the exclusion of the descriptor, which
  is the property the whole design rests on. So the id is a hash: stable for a given
  locator and path, distinct across bundles, and carrying no path material.

  ## Where the bytes are

  In the descriptor, which is not serialized — and it carries **only the locator**. The file's
  own address is `record.path`, which is serialized because a model needs it to choose a file;
  writing it into `params` as well would state the same fact twice and invite the two to
  drift. What the descriptor holds is the one thing that must never be shown: the bundle root
  a read is confined to.

  Acceptance is left open (`as: :auto`, no `max_bytes`) because a *listing* cannot know what
  its consumer can accept — each caller narrows at materialize time. Baking `as: :text` here
  would make the same record useless to a byte consumer such as a BO preview.
  """

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage

  @provider "zaq_skill_bundle"
  @resource_type :skill_bundle_file
  @types [:references, :assets, :scripts]

  @type locator :: String.t()

  @doc """
  Converts a Jido-shaped listing into a page of records.

  The three resource types are **not** kept apart. Each record's `path` already carries its
  type directory (`references/guide.md`), so a per-type map would encode the same fact twice
  and every consumer would have to flatten it back. Type ordering survives as list order:
  references first, then assets, then scripts, so a truncated page drops the least useful
  entries first.
  """
  @spec from_listing(map(), locator()) :: RecordPage.t()
  def from_listing(listing, locator) when is_map(listing) and is_binary(locator) do
    @types
    |> Enum.flat_map(fn type ->
      listing |> Map.get(type, []) |> Enum.map(&from_entry(&1, locator))
    end)
    |> then(&RecordPage.new(@resource_type, &1))
  end

  @doc """
  An empty page — a bundle with nothing in it, or a locator no volume holds.

  Not an error: a skill with no files uploaded is an ordinary state.
  """
  @spec empty_page() :: RecordPage.t()
  def empty_page, do: RecordPage.empty(@resource_type)

  @doc "The `resource_type` every bundle page carries."
  @spec resource_type() :: atom()
  def resource_type, do: @resource_type

  @doc """
  Converts one listing entry into a record handle.

  Accepts Jido's entry shape (`:name`, `:relative_path`, `:size`, `:modified`). Any
  `:absolute_path` on the entry is ignored rather than mapped.
  """
  @spec from_entry(map(), locator()) :: Record.t()
  def from_entry(entry, locator) when is_map(entry) and is_binary(locator) do
    resource_path = Map.fetch!(entry, :relative_path)
    name = Map.fetch!(entry, :name)

    %Record{
      id: record_id(locator, resource_path),
      kind: :file,
      name: name,
      path: resource_path,
      size: Map.get(entry, :size),
      modified_at: Map.get(entry, :modified),
      mime_type: MIME.from_path(name),
      attributes: %{"provider" => @provider},
      materialization: descriptor(locator)
    }
  end

  @doc """
  A stable, opaque identifier for one file in one bundle.

  Hashed rather than interpolated — see the module doc. The null separator keeps
  `("a", "bc")` and `("ab", "c")` from hashing to the same value.
  """
  @spec record_id(locator(), String.t()) :: String.t()
  def record_id(locator, resource_path) when is_binary(locator) and is_binary(resource_path) do
    digest = :crypto.hash(:sha256, locator <> <<0>> <> resource_path)

    @provider <> ":" <> Base.url_encode64(digest, padding: false)
  end

  # The bundle root a read is confined to, and nothing else. Which file inside it is
  # `record.path`, which the reader takes off the record it was handed.
  defp descriptor(locator), do: Materialization.new(:ingestion, params: %{locator: locator})
end
