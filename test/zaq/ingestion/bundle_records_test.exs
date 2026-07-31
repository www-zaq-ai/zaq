defmodule Zaq.Ingestion.BundleRecordsTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.BundleRecords

  @locator ".agents/skills/pricing-faq"
  @modified ~U[2026-07-30 12:00:00Z]

  defp entry(name, type \\ "references", size \\ 128) do
    %{
      name: name,
      relative_path: "#{type}/#{name}",
      absolute_path: "/zaq/volumes/library/#{@locator}/#{type}/#{name}",
      size: size,
      modified: @modified
    }
  end

  defp listing(overrides \\ %{}) do
    Map.merge(%{references: [], assets: [], scripts: []}, overrides)
  end

  # Walks anything — structs, maps, lists, tuples — collecting every string it can reach.
  # A leak assertion that only checks top-level keys is the kind that passes while a volume
  # sits two levels down in a descriptor's params.
  defp all_strings(%DateTime{}), do: []
  defp all_strings(%_{} = struct), do: struct |> Map.from_struct() |> all_strings()

  defp all_strings(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} -> all_strings(k) ++ all_strings(v) end)
  end

  defp all_strings(list) when is_list(list), do: Enum.flat_map(list, &all_strings/1)
  defp all_strings(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> all_strings()
  defp all_strings(value) when is_binary(value), do: [value]
  defp all_strings(value) when is_atom(value), do: [Atom.to_string(value)]
  defp all_strings(_value), do: []

  describe "from_listing/2" do
    test "mints a record per entry, keeping the three types apart" do
      listing =
        BundleRecords.from_listing(
          listing(%{references: [entry("guide.md")], assets: [entry("logo.png", "assets")]}),
          @locator
        )

      assert [%Record{name: "guide.md"}] = listing.references
      assert [%Record{name: "logo.png"}] = listing.assets
      assert listing.scripts == []
    end

    test "carries the metadata a model needs to choose a file" do
      %{references: [record]} =
        BundleRecords.from_listing(listing(%{references: [entry("guide.md")]}), @locator)

      assert record.kind == :file
      assert record.path == "references/guide.md"
      assert record.size == 128
      assert record.modified_at == @modified
      assert record.attributes["resource_path"] == "references/guide.md"
      assert record.attributes["provider"] == "zaq_skill_bundle"
    end

    test "infers mime_type from the extension" do
      %{references: [md], assets: [png]} =
        BundleRecords.from_listing(
          listing(%{references: [entry("guide.md")], assets: [entry("logo.png", "assets")]}),
          @locator
        )

      assert md.mime_type == "text/markdown"
      assert png.mime_type == "image/png"
    end

    test "an empty listing mints nothing" do
      assert BundleRecords.from_listing(listing(), @locator) == %{
               references: [],
               assets: [],
               scripts: []
             }
    end
  end

  describe "the descriptor" do
    test "routes to ingestion's skill_bundle strategy" do
      %{references: [record]} =
        BundleRecords.from_listing(listing(%{references: [entry("guide.md")]}), @locator)

      assert %Materialization{role: :ingestion, strategy: :skill_bundle} = record.materialization
    end

    test "carries the locator it was minted from, and the resource path" do
      %{references: [record]} =
        BundleRecords.from_listing(listing(%{references: [entry("guide.md")]}), @locator)

      assert record.materialization.params == %{
               locator: @locator,
               resource_path: "references/guide.md"
             }
    end

    # A listing cannot know what its consumer accepts — each caller narrows at materialize
    # time. Baking `as: :text` here would make the same record useless to a byte consumer.
    test "leaves acceptance open" do
      %{references: [record]} =
        BundleRecords.from_listing(listing(%{references: [entry("guide.md")]}), @locator)

      assert record.materialization.as == :auto
      assert record.materialization.max_bytes == nil
    end
  end

  describe "leak guards" do
    setup do
      %{references: [record]} =
        BundleRecords.from_listing(listing(%{references: [entry("guide.md")]}), @locator)

      %{record: record, strings: all_strings(record)}
    end

    # Jido hands us `:absolute_path` on every entry. It discloses the ingestion node's
    # filesystem layout to whatever called across the boundary, and through a tool result to
    # a model. It must not survive minting, at any nesting level.
    test "no absolute path survives, anywhere in the struct", %{strings: strings} do
      refute Enum.any?(strings, &String.starts_with?(&1, "/"))
      refute Enum.any?(strings, &(&1 =~ "absolute_path"))
    end

    test "no volume name survives, anywhere in the struct", %{strings: strings} do
      refute Enum.any?(strings, &(&1 =~ "library"))
      refute Enum.any?(strings, &(&1 =~ "volume"))
    end

    # `:id` IS in Record's Jason.Encoder derive list, so an id built by interpolating the
    # locator would render it into every encoded record — undoing the descriptor exclusion
    # that the whole design rests on.
    test "the id does not embed the locator", %{record: record} do
      refute record.id =~ @locator
      refute record.id =~ ".agents"
    end

    test "encoding the record discloses neither the locator nor the descriptor", %{
      record: record
    } do
      encoded = Jason.encode!(record)

      refute encoded =~ @locator
      refute encoded =~ "materialization"
    end
  end

  describe "record_id/2" do
    test "is stable for the same locator and path" do
      assert BundleRecords.record_id(@locator, "references/guide.md") ==
               BundleRecords.record_id(@locator, "references/guide.md")
    end

    test "differs across bundles holding the same path" do
      refute BundleRecords.record_id(@locator, "references/guide.md") ==
               BundleRecords.record_id(".agents/skills/other", "references/guide.md")
    end

    test "differs across paths within one bundle" do
      refute BundleRecords.record_id(@locator, "references/guide.md") ==
               BundleRecords.record_id(@locator, "references/other.md")
    end

    # Without a separator, ("a", "bc") and ("ab", "c") would hash identically.
    test "does not collide when the split between locator and path shifts" do
      refute BundleRecords.record_id("a", "bc") == BundleRecords.record_id("ab", "c")
    end
  end
end
