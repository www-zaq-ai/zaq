defmodule Zaq.Ingestion.PermissionTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Ingestion.{Document, Permission}

  defp create_doc do
    {:ok, doc} =
      Document.create(%{
        source: "perm-schema-#{System.unique_integer([:positive])}.md",
        content: "content"
      })

    doc
  end

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{"full_name" => "Person #{unique}", "email" => "p#{unique}@test.com"})

    person
  end

  defp create_team do
    {:ok, team} = People.create_team(%{name: "Team #{System.unique_integer([:positive])}"})
    team
  end

  describe "changeset/2" do
    test "valid with person_id" do
      doc = create_doc()
      person = create_person()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          person_id: person.id,
          access_rights: ["read"]
        })

      assert changeset.valid?
    end

    test "valid with team_id" do
      doc = create_doc()
      team = create_team()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          team_id: team.id,
          access_rights: ["read"]
        })

      assert changeset.valid?
    end

    test "invalid when neither person_id nor team_id is set" do
      doc = create_doc()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          access_rights: ["read"]
        })

      refute changeset.valid?
      assert {"must set person_id or team_id", _} = changeset.errors[:base]
    end

    test "invalid when document_id is missing" do
      person = create_person()

      changeset =
        Permission.changeset(%Permission{}, %{
          person_id: person.id,
          access_rights: ["read"]
        })

      refute changeset.valid?
      assert changeset.errors[:document_id]
    end

    test "invalid when access_rights contains unknown right" do
      doc = create_doc()
      person = create_person()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          person_id: person.id,
          access_rights: ["read", "fly"]
        })

      refute changeset.valid?
      assert changeset.errors[:access_rights]
    end

    test "allows all valid access_rights" do
      doc = create_doc()
      person = create_person()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          person_id: person.id,
          access_rights: ["read", "write", "update", "delete"]
        })

      assert changeset.valid?
    end

    test "defaults access_rights to ['read'] when not provided" do
      doc = create_doc()
      person = create_person()

      changeset =
        Permission.changeset(%Permission{}, %{
          document_id: doc.id,
          person_id: person.id
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :access_rights) == ["read"]
    end
  end
end
