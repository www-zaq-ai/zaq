defmodule Zaq.Contracts.RecordTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Plug.Crypto.{KeyGenerator, MessageVerifier}
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

    test "rebuilds atom-keyed public fields after Map.from_struct" do
      {:ok, sealed} = Provenance.seal(record(%{provenance_ref: nil}))

      assert {:ok, rebuilt} = sealed |> Map.from_struct() |> Record.from_map()
      assert rebuilt.id == sealed.id
      assert rebuilt.kind == sealed.kind
      assert rebuilt.materialization_handle == sealed.materialization_handle
      assert rebuilt.provenance_ref == sealed.provenance_ref
      assert rebuilt.raw == %{}
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

    test "can validate trusted native Record structs without provenance" do
      schema = Record.zoi_type(verify_provenance: false)

      assert {:ok, %Record{}} = Zoi.parse(schema, record(%{provenance_ref: nil}))
      assert {:error, _errors} = Zoi.parse(schema, %{"id" => "42", "kind" => "file"})
      assert {:error, _errors} = Zoi.parse(schema, "not-a-record")
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

  describe "from_map/1" do
    test "rejects non-map values" do
      for value <- [nil, [], "not-a-record", :record] do
        assert {:error, :invalid_record} = Record.from_map(value)
      end
    end
  end

  test "zoi record transform passes scalar values through but the schema rejects them" do
    assert Record.zoi_record_from_map("not-a-record", []) == {:ok, "not-a-record"}
    assert {:error, _errors} = Zoi.parse(Record.zoi_type(), "not-a-record")
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

    test "issues with default claims and rejects invalid public inputs" do
      assert {:ok, ref} = Provenance.issue(record(%{provenance_ref: nil}))
      assert is_binary(ref)

      assert {:error, :invalid_record_provenance} =
               Provenance.issue(%{}, %{}, secret_key_base: @secret_key_base)

      assert {:error, :invalid_record_provenance} =
               Provenance.issue(record(%{provenance_ref: nil}), [],
                 secret_key_base: @secret_key_base
               )

      assert {:error, :invalid_record_provenance} =
               Provenance.verify(%{provenance_ref: ref}, secret_key_base: @secret_key_base)
    end

    test "issues recursively canonicalized claims and gives record claims precedence" do
      source =
        record(%{attributes: %{"provider_record_id" => "provider-42"}, provenance_ref: nil})

      claims = %{
        "record_id" => "forged",
        "provider_record_id" => "forged-provider",
        custom_key: %{
          nested_atom: [:atom_value, "text", 7, true, nil],
          nested_list: [%{deep_key: :deep_value}]
        },
        kind: :forged,
        custom_nil: nil
      }

      assert {:ok, ref} = Provenance.issue(source, claims, secret_key_base: @secret_key_base)
      assert is_binary(ref)

      assert {:ok, verified} =
               Provenance.verify(%{source | provenance_ref: ref},
                 secret_key_base: @secret_key_base
               )

      assert verified["provider_record_id"] == "provider-42"
      assert verified["record_id"] == "42"
      assert verified["kind"] == "file"

      assert verified["custom_key"] == %{
               "nested_atom" => ["atom_value", "text", 7, "true", "nil"],
               "nested_list" => [%{"deep_key" => "deep_value"}]
             }

      assert verified["custom_nil"] == "nil"
    end

    test "returns the same provenance error when claims cannot be encoded" do
      source = record(%{provenance_ref: nil})
      bad_claims = %{"custom" => self()}

      assert {:error, :invalid_record_provenance} =
               Provenance.issue(source, bad_claims, secret_key_base: @secret_key_base)

      assert {:error, :invalid_record_provenance} =
               Provenance.seal(source, bad_claims, secret_key_base: @secret_key_base)
    end

    test "rejects malformed, unsupported, and extra-key payloads" do
      assert {:error, :invalid_record_provenance} =
               Provenance.verify(%{record() | provenance_ref: "nope"},
                 secret_key_base: @secret_key_base
               )

      assert {:error, :unsupported_record_provenance} =
               Provenance.verify(
                 %{
                   record()
                   | provenance_ref: sign_provenance_payload(%{"v" => 2, "claims" => %{}})
                 },
                 secret_key_base: @secret_key_base
               )

      assert {:error, :unsupported_record_provenance} =
               Provenance.verify(
                 %{
                   record()
                   | provenance_ref: sign_provenance_payload(%{"v" => 1, "claims" => []})
                 },
                 secret_key_base: @secret_key_base
               )

      assert {:error, :invalid_record_provenance} =
               Provenance.verify(
                 %{
                   record()
                   | provenance_ref:
                       sign_provenance_payload(%{"v" => 1, "claims" => %{}, "extra" => true})
                 },
                 secret_key_base: @secret_key_base
               )

      assert {:error, :invalid_record_provenance} =
               Provenance.verify(
                 %{record() | provenance_ref: sign_provenance_payload(%{})},
                 secret_key_base: @secret_key_base
               )
    end

    test "normalizes scalar permission rights from atom-keyed attributes" do
      source =
        record(%{
          permissions: [permission("p1", %{target_id: " TEAM ", access_rights: :read})],
          provenance_ref: nil
        })

      assert {:ok, ref} = Provenance.issue(source, %{}, secret_key_base: @secret_key_base)

      assert {:ok, claims} =
               Provenance.verify(%{source | provenance_ref: ref},
                 secret_key_base: @secret_key_base
               )

      assert [%{"permission_id" => "p1", "principal" => %{"key" => "team"}, "rights" => ["read"]}] =
               claims["permissions"]["entries"]
    end

    test "normalizes invalid permission entries and non-binary principal keys" do
      source =
        record(%{
          permissions: [
            :invalid,
            permission("p1", %{
              "target_id" => 123,
              "inherited" => true,
              "access_rights" => ["read"]
            }),
            permission("p2", %{
              "target_id" => :team,
              "inherited" => "true",
              "access_rights" => ["comment"]
            }),
            permission("p3", %{
              "target_id" => "group",
              "inherited" => "false",
              "access_rights" => ["write"]
            }),
            permission("p4", %{
              "target_id" => "other",
              "inherited" => :unknown,
              "access_rights" => ["read"]
            })
          ],
          provenance_ref: nil
        })

      assert {:ok, ref} = Provenance.issue(source, %{}, secret_key_base: @secret_key_base)

      assert {:ok, claims} =
               Provenance.verify(%{source | provenance_ref: ref},
                 secret_key_base: @secret_key_base
               )

      assert %{"invalid" => "invalid"} in claims["permissions"]["entries"]

      assert Enum.any?(claims["permissions"]["entries"], fn entry ->
               entry["permission_id"] == "p1" and
                 entry["principal"]["key"] == 123 and entry["inherited"] == true
             end)

      assert Enum.any?(claims["permissions"]["entries"], fn entry ->
               entry["permission_id"] == "p2" and
                 entry["principal"]["key"] == "team" and entry["inherited"] == true
             end)

      assert Enum.any?(claims["permissions"]["entries"], fn entry ->
               entry["permission_id"] == "p3" and entry["inherited"] == false
             end)

      assert Enum.any?(claims["permissions"]["entries"], fn entry ->
               entry["permission_id"] == "p4" and entry["inherited"] == "unknown"
             end)
    end

    test "normalizes date and time claims" do
      source = record(%{provenance_ref: nil})

      claims = %{
        datetime: ~U[2026-09-01 12:34:56Z],
        naive_datetime: ~N[2026-09-01 12:34:56],
        date: ~D[2026-09-01],
        time: ~T[12:34:56]
      }

      assert {:ok, ref} = Provenance.issue(source, claims, secret_key_base: @secret_key_base)

      assert {:ok, verified} =
               Provenance.verify(%{source | provenance_ref: ref},
                 secret_key_base: @secret_key_base
               )

      assert verified["datetime"] == "2026-09-01T12:34:56Z"
      assert verified["naive_datetime"] == "2026-09-01T12:34:56"
      assert verified["date"] == "2026-09-01"
      assert verified["time"] == "12:34:56"
    end

    test "uses the configured endpoint secret when options are omitted" do
      {:ok, sealed} = Provenance.seal(record(%{provenance_ref: nil}))
      assert {:ok, claims} = Provenance.verify(sealed)
      assert claims["record_id"] == "42"
    end

    property "JSON-safe nested claims survive issue and verify" do
      check all(claims <- claims_generator()) do
        source = record(%{provenance_ref: nil})
        assert {:ok, ref} = Provenance.issue(source, claims, secret_key_base: @secret_key_base)

        assert {:ok, verified} =
                 Provenance.verify(%{source | provenance_ref: ref},
                   secret_key_base: @secret_key_base
                 )

        expected = claims |> Jason.encode!() |> Jason.decode!() |> current_provenance_values()

        assert Map.merge(expected, %{
                 "record_id" => "42",
                 "provider_record_id" => "42",
                 "kind" => "file",
                 "parent_id" => "nil",
                 "permissions" => %{"state" => "not_loaded", "entries" => nil}
               }) == verified
      end
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

  describe "metadata/1 nested permissions" do
    test "keeps permission metadata but excludes content and raw" do
      permission = %Record{
        id: "p1",
        kind: :permission,
        content: "private",
        raw: %{provider: "secret"},
        attributes: %{"target_id" => "team", "role" => "reader"}
      }

      metadata = Record.metadata(record(%{permissions: [permission]}))

      assert [%{"id" => "p1", "kind" => "permission", "attributes" => attributes}] =
               metadata["permissions"]

      assert attributes == %{"target_id" => "team", "role" => "reader"}
      refute Map.has_key?(hd(metadata["permissions"]), "content")
      refute Map.has_key?(hd(metadata["permissions"]), "raw")
    end
  end

  test "round trips an unknown runtime kind" do
    kind = "runtime-kind-#{System.unique_integer([:positive])}"
    {:ok, sealed} = Provenance.seal(record(%{kind: kind, provenance_ref: nil}))

    assert {:ok, rebuilt} = sealed |> Jason.encode!() |> Jason.decode!() |> Record.from_map()
    assert rebuilt.kind == kind
    assert is_binary(rebuilt.kind)
  end

  defp claims_generator do
    value = nested_value_generator(2)

    StreamData.map_of(StreamData.string(:printable, min_length: 1, max_length: 10), value,
      max_length: 4
    )
  end

  defp nested_value_generator(0) do
    StreamData.one_of([
      StreamData.string(:printable, max_length: 20),
      StreamData.integer(),
      StreamData.boolean()
    ])
  end

  defp nested_value_generator(depth) do
    StreamData.one_of([
      nested_value_generator(0),
      StreamData.list_of(nested_value_generator(depth - 1), max_length: 3),
      StreamData.map_of(
        StreamData.string(:printable, max_length: 10),
        nested_value_generator(depth - 1),
        max_length: 3
      )
    ])
  end

  defp current_provenance_values(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, current_provenance_values(nested)} end)

  defp current_provenance_values(value) when is_list(value),
    do: Enum.map(value, &current_provenance_values/1)

  defp current_provenance_values(value) when is_boolean(value), do: Atom.to_string(value)
  defp current_provenance_values(nil), do: "nil"
  defp current_provenance_values(value), do: value

  defp sign_provenance_payload(payload) do
    secret = KeyGenerator.generate(@secret_key_base, "zaq.record.provenance")
    MessageVerifier.sign(Jason.encode!(payload), secret)
  end

  defp permission(id, attributes) do
    %Record{id: id, kind: :permission, attributes: attributes}
  end
end
