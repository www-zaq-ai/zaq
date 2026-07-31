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

  In the descriptor, which is not serialized. `role: :ingestion`, `strategy: :skill_bundle`,
  and `params` holding the locator and resource path. Acceptance is left open (`as: :auto`,
  no `max_bytes`) because a *listing* cannot know what its consumer can accept — each caller
  narrows at materialize time. Baking `as: :text` here would make the same record useless to
  a byte consumer such as a BO preview.
  """

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record

  @provider "zaq_skill_bundle"
  @types [:references, :assets, :scripts]

  @type locator :: String.t()

  @doc "Converts a Jido-shaped listing into records, keeping the three resource types apart."
  @spec from_listing(map(), locator()) :: %{
          references: [Record.t()],
          assets: [Record.t()],
          scripts: [Record.t()]
        }
  def from_listing(listing, locator) when is_map(listing) and is_binary(locator) do
    Map.new(@types, fn type ->
      {type, listing |> Map.get(type, []) |> Enum.map(&from_entry(&1, locator))}
    end)
  end

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
      attributes: %{"provider" => @provider, "resource_path" => resource_path},
      materialization: descriptor(locator, resource_path)
    }
  end

  @doc """
  The descriptor pointing at one file in a bundle.

  Exposed so the persist path can hand back a handle for a file it just wrote without
  re-listing the bundle to find it.
  """
  @spec descriptor(locator(), String.t()) :: Materialization.t()
  def descriptor(locator, resource_path) when is_binary(locator) and is_binary(resource_path) do
    Materialization.new(:ingestion, :skill_bundle,
      params: %{locator: locator, resource_path: resource_path}
    )
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
end
