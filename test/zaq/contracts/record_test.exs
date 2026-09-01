defmodule Zaq.Contracts.RecordTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

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
        provenance_ref: "signed-provenance",
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
      assert decoded["provenance_ref"] == "signed-provenance"
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
      {:ok, sealed} = Provenance.seal(record(%{provenance_ref: nil}))

      assert {:ok, rebuilt} =
               sealed
               |> Jason.encode!()
               |> Jason.decode!()
               |> Record.from_map()

      assert rebuilt.id == "42"
      assert rebuilt.materialization_handle == "signed-handle"
      assert rebuilt.raw == %{}
    end

    test "rebuilds nested public permission maps without raw provider internals" do
      {:ok, sealed_permission} =
        permission("p1", %{"target_id" => "u1", "access_rights" => ["read"]})
        |> Provenance.seal()

      {:ok, sealed} =
        record(%{permissions: [sealed_permission], provenance_ref: nil})
        |> Provenance.seal()

      encoded =
        sealed
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, rebuilt} = Record.from_map(encoded)
      assert [%Record{id: "p1", kind: :permission, raw: %{}}] = rebuilt.permissions
      assert rebuilt.provenance_ref == sealed.provenance_ref
    end
  end

  describe "metadata/1" do
    test "keeps stable public fields and excludes content and runtime fields" do
      metadata = Record.metadata(record())

      assert metadata["id"] == "42"
      assert metadata["kind"] == "file"
      assert metadata["name"] == "guide.md"
      assert metadata["attributes"] == %{"provider" => "disk"}
      assert metadata["provenance_ref"] == "signed-provenance"
      refute Map.has_key?(metadata, "content")
      refute Map.has_key?(metadata, "raw")
      refute Map.has_key?(metadata, "materializing_event")
    end
  end

  test "id and kind are enforced" do
    assert_raise ArgumentError, fn -> struct!(Record, name: "guide.md") end
  end

  describe "zoi_type/1" do
    test "accepts signed records and rejects unsigned records and maps" do
      schema = Record.zoi_type()
      {:ok, sealed} = Provenance.seal(record(%{provenance_ref: nil}))

      assert {:ok, %Record{}} = Zoi.parse(schema, sealed)
      assert {:error, _errors} = Zoi.parse(schema, record(%{provenance_ref: nil}))
      assert {:error, _errors} = Zoi.parse(schema, %{"id" => "42", "kind" => "file"})
    end

    test "encodes to JSON Schema for tool catalog validation" do
      assert is_map(Zoi.JSONSchema.encode(Record.zoi_type(description: "A ZAQ record")))
    end
  end

  describe "zoi_type/1 with JSON-safe maps" do
    test "rebuilds and verifies JSON-safe Records" do
      {:ok, sealed} = Provenance.seal(record(%{provenance_ref: nil}))
      decoded = sealed |> Jason.encode!() |> Jason.decode!()

      assert {:ok, %Record{id: "42"}} = Zoi.parse(Record.zoi_type(), decoded)
    end

    test "rejects unsigned public Record maps" do
      decoded = record(%{provenance_ref: nil}) |> Jason.encode!() |> Jason.decode!()

      assert {:error, _errors} = Zoi.parse(Record.zoi_type(), decoded)
    end
  end

  describe "Provenance" do
    @secret_key_base String.duplicate("a", 64)

    test "seals and verifies canonical record claims" do
      {:ok, sealed} =
        record(%{provenance_ref: nil})
        |> Provenance.seal(%{"provider" => "disk", "config_id" => "1"},
          secret_key_base: @secret_key_base
        )

      assert is_binary(sealed.provenance_ref)
      assert {:ok, claims} = Provenance.verify(sealed, secret_key_base: @secret_key_base)
      assert claims["provider"] == "disk"
      assert claims["config_id"] == "1"
      assert claims["record_id"] == "42"
      assert claims["kind"] == "file"
      assert claims["permissions"] == %{"state" => "not_loaded", "entries" => nil}
    end

    test "distinguishes not-loaded permissions from loaded-empty permissions" do
      {:ok, not_loaded} =
        record(%{permissions: nil, provenance_ref: nil})
        |> Provenance.seal(%{}, secret_key_base: @secret_key_base)

      loaded_empty = %{not_loaded | permissions: []}

      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(loaded_empty, secret_key_base: @secret_key_base)
    end

    test "permission ordering does not affect verification" do
      permissions = [
        permission("p2", %{"target_id" => "TEAM", "access_rights" => ["write", "read"]}),
        permission("p1", %{"email" => "USER@example.COM", "role" => "reader"})
      ]

      {:ok, sealed} =
        record(%{permissions: permissions, provenance_ref: nil})
        |> Provenance.seal(%{}, secret_key_base: @secret_key_base)

      reordered = %{sealed | permissions: Enum.reverse(permissions)}

      assert {:ok, _claims} = Provenance.verify(reordered, secret_key_base: @secret_key_base)
    end

    test "permission semantic tampering invalidates verification" do
      permission = permission("p1", %{"target_id" => "team", "access_rights" => ["read"]})

      {:ok, sealed} =
        record(%{permissions: [permission], provenance_ref: nil})
        |> Provenance.seal(%{}, secret_key_base: @secret_key_base)

      tampered_permission = %{
        permission
        | attributes: %{"target_id" => "team", "access_rights" => ["write"]}
      }

      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(%{sealed | permissions: [tampered_permission]},
                 secret_key_base: @secret_key_base
               )
    end

    test "record identity tampering invalidates verification" do
      {:ok, sealed} =
        record(%{provenance_ref: nil})
        |> Provenance.seal(%{}, secret_key_base: @secret_key_base)

      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(%{sealed | id: "other"}, secret_key_base: @secret_key_base)
    end

    test "parent_ids and modified_at are metadata, not provenance claims" do
      {:ok, sealed} =
        record(%{
          parent_ids: ["parent-a"],
          modified_at: ~U[2026-08-27 10:19:18Z],
          provenance_ref: nil
        })
        |> Provenance.seal(%{}, secret_key_base: @secret_key_base)

      changed = %{
        sealed
        | parent_ids: [],
          modified_at: %{
            "__struct__" => "DateTime",
            "year" => 2026,
            "month" => 8,
            "day" => 27
          }
      }

      assert {:ok, _claims} = Provenance.verify(changed, secret_key_base: @secret_key_base)
    end
  end

  defp permission(id, attributes) do
    %Record{id: id, kind: :permission, attributes: attributes}
  end
end
