defmodule Zaq.Contracts.Record.ProvenancePrincipalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.{Authorization, Provenance}

  property "changing a nested principal cannot preserve provenance while granting read access" do
    check all(
            owner <- string(:alphanumeric, min_length: 1),
            attacker <- string(:alphanumeric, min_length: 1),
            String.downcase(owner) != String.downcase(attacker),
            representation <- member_of([:channel, :type, :atoms])
          ) do
      person = %Person{id: 1, email: attacker <> "@example.test", channels: []}
      principal = principal(representation, owner <> "@example.test")
      record = seal(principal)
      refute Authorization.can?(person, record, :read)

      [permission] = record.permissions

      forged = %{
        record
        | permissions: [
            %{
              permission
              | attributes:
                  Map.put(
                    permission.attributes,
                    "principal",
                    principal(representation, person.email)
                  )
            }
          ]
      }

      assert Authorization.can?(person, forged, :read)
      assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
      assert {:ok, _} = Provenance.verify(record)
    end
  end

  test "nested and flat principal_channel overrides are authenticated, including invalid nested maps" do
    record = seal(%{})
    [permission] = record.permissions

    for attrs <- [
          Map.put(
            permission.attributes,
            "principal",
            principal(:channel, "attacker@example.test")
          ),
          permission.attributes
          |> Map.delete("principal")
          |> Map.put("principal_channel", "mattermost")
        ] do
      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(%{record | permissions: [%{permission | attributes: attrs}]})
    end

    flat = %{permission | attributes: Map.delete(permission.attributes, "principal")}
    {:ok, record} = Provenance.seal(%{record | permissions: [flat]})
    edited = %{flat | attributes: Map.put(flat.attributes, "principal_channel", "mattermost")}

    assert {:error, :record_provenance_mismatch} =
             Provenance.verify(%{record | permissions: [edited]})
  end

  test "flat provider principal projection remains unchanged" do
    permission = %Record{
      id: "acl",
      kind: :permission,
      attributes: %{
        "principal_type" => "email",
        "principal_key" => "owner@example.test",
        "access_rights" => ["read"]
      }
    }

    projection = Provenance.permission_projection([permission])

    assert hd(projection["entries"])["principal"] == %{
             "type" => "email",
             "key" => "owner@example.test"
           }
  end

  defp principal(:channel, email), do: %{"channel" => "email", "identifier" => email}
  defp principal(:type, email), do: %{"type" => "email", "key" => email}
  defp principal(:atoms, email), do: %{channel: "email", identifier: email}

  defp seal(principal) do
    permission = %Record{
      id: "acl",
      kind: :permission,
      attributes: %{
        "principal_type" => "email",
        "principal_key" => "owner@example.test",
        "principal" => principal,
        "access_rights" => ["read"]
      }
    }

    {:ok, record} =
      Provenance.seal(%Record{id: "private", kind: :file, permissions: [permission]})

    record
  end
end
