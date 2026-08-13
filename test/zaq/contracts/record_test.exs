defmodule Zaq.Contracts.RecordTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Event

  # Every field that must never leave the struct. Kept as a literal here on purpose: if the
  # struct grows a field carrying provider internals or a dispatchable capability, one of
  # these tests should fail rather than the field quietly appearing in a tool result.
  @private_fields [:materializing_event, :raw]

  defp record(attrs \\ %{}) do
    struct!(
      %Record{
        id: "42",
        kind: :file,
        name: "guide.md",
        mime_type: "text/markdown",
        content: "# guide",
        path: "manuals/guide.md",
        attributes: %{"provider" => "disk"},
        raw: %{local_entry: %{name: "guide.md"}},
        materializing_event:
          Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])
      },
      attrs
    )
  end

  describe "to_map/1" do
    test "returns every struct field except the private ones" do
      expected =
        record()
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--(@private_fields)
        |> Enum.sort()

      assert record() |> Record.to_map() |> Map.keys() |> Enum.sort() == expected
    end

    test "drops raw and materializing_event" do
      map = Record.to_map(record())

      for field <- @private_fields do
        refute Map.has_key?(map, field), "#{field} must not travel in to_map/1"
      end
    end

    test "keeps the public values intact" do
      map = Record.to_map(record())

      assert map.id == "42"
      assert map.kind == :file
      assert map.content == "# guide"
      assert map.attributes == %{"provider" => "disk"}
      assert map.parent_ids == []
      assert map.owners == []
    end

    test "returns a plain map, not a struct" do
      refute is_struct(Record.to_map(record()))
    end
  end

  describe "Jason encoding" do
    test "encodes exactly the fields to_map/1 returns" do
      # The encoder and `to_map/1` read one list precisely so they cannot drift apart and
      # expose a field through one path but not the other.
      encoded_keys = record() |> Jason.encode!() |> Jason.decode!() |> Map.keys() |> Enum.sort()

      to_map_keys =
        record() |> Record.to_map() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert encoded_keys == to_map_keys
    end

    test "omits raw and materializing_event" do
      decoded = record() |> Jason.encode!() |> Jason.decode!()

      for field <- @private_fields do
        refute Map.has_key?(decoded, Atom.to_string(field)),
               "#{field} must not travel in the JSON projection"
      end
    end

    test "a record encodes even when it carries an event" do
      # A `%Zaq.Event{}` has no encoder — the record only encodes because the event is
      # excluded from the derived field list.
      assert is_binary(Jason.encode!(record()))
    end
  end

  describe "round trip through JSON" do
    test "comes back without the event, and therefore cannot be materialized" do
      rebuilt =
        record()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
        |> then(&struct(Record, &1))

      assert rebuilt.id == "42"
      assert rebuilt.materializing_event == nil
      assert rebuilt.raw == %{}
    end
  end

  test "id and kind are enforced" do
    assert_raise ArgumentError, fn -> struct!(Record, name: "guide.md") end
  end
end
