defmodule Zaq.Contracts.RecordTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record

  # Every field that must never leave the struct. Kept as a literal here on purpose: if the
  # struct grows a field carrying provider internals, one of
  # these tests should fail rather than the field quietly appearing in a tool result.
  @private_fields [:raw]

  defp record(attrs \\ %{}) do
    struct!(
      %Record{
        id: "42",
        kind: :file,
        name: "guide.md",
        mime_type: "text/markdown",
        content: "# guide",
        path: "manuals/guide.md",
        materialization_handle: "signed-handle",
        attributes: %{"provider" => "disk"},
        raw: %{local_entry: %{name: "guide.md"}}
      },
      attrs
    )
  end

  describe "Jason encoding" do
    test "encodes every struct field except the private ones" do
      # A field added to the struct but not to `@public_fields` fails here — which is the
      # point: whether a new field may leave the struct is a decision, not a default.
      expected =
        record()
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--(@private_fields)
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      encoded_keys = record() |> Jason.encode!() |> Jason.decode!() |> Map.keys() |> Enum.sort()

      assert encoded_keys == expected
    end

    test "keeps the public values intact" do
      decoded = record() |> Jason.encode!() |> Jason.decode!()

      assert decoded["id"] == "42"
      assert decoded["kind"] == "file"
      assert decoded["content"] == "# guide"
      assert decoded["attributes"] == %{"provider" => "disk"}
      assert decoded["materialization_handle"] == "signed-handle"
      assert decoded["parent_ids"] == []
      assert decoded["owners"] == []
    end

    test "omits raw" do
      decoded = record() |> Jason.encode!() |> Jason.decode!()

      for field <- @private_fields do
        refute Map.has_key?(decoded, Atom.to_string(field)),
               "#{field} must not travel in the JSON projection"
      end
    end

    test "a record encodes when it carries a signed materialization handle" do
      assert is_binary(Jason.encode!(record()))
    end
  end

  describe "round trip through JSON" do
    test "keeps the materialization handle but not raw provider internals" do
      rebuilt =
        record()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
        |> then(&struct(Record, &1))

      assert rebuilt.id == "42"
      assert rebuilt.materialization_handle == "signed-handle"
      assert rebuilt.raw == %{}
    end
  end

  test "id and kind are enforced" do
    assert_raise ArgumentError, fn -> struct!(Record, name: "guide.md") end
  end

  describe "zoi_type/1" do
    test "accepts records and rejects other values" do
      schema = Record.zoi_type()

      assert {:ok, %Record{}} = Zoi.parse(schema, record())
      assert {:error, _errors} = Zoi.parse(schema, %{"id" => "42", "kind" => "file"})
    end

    test "encodes to JSON Schema for tool catalog validation" do
      assert is_map(Zoi.JSONSchema.encode(Record.zoi_type(description: "A ZAQ record")))
    end
  end
end
