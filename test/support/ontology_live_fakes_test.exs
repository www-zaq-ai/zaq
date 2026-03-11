defmodule Zaq.TestSupport.OntologyLiveFakesTest do
  use ExUnit.Case, async: true

  alias LicenseManager.Paid.Ontology.Business
  alias LicenseManager.Paid.Ontology.Businesses
  alias LicenseManager.Paid.Ontology.Channel
  alias LicenseManager.Paid.Ontology.Department
  alias LicenseManager.Paid.Ontology.Departments
  alias LicenseManager.Paid.Ontology.Division
  alias LicenseManager.Paid.Ontology.Divisions
  alias LicenseManager.Paid.Ontology.KnowledgeDomain
  alias LicenseManager.Paid.Ontology.KnowledgeDomains
  alias LicenseManager.Paid.Ontology.People
  alias LicenseManager.Paid.Ontology.Team
  alias LicenseManager.Paid.Ontology.TeamMember
  alias LicenseManager.Paid.Ontology.Teams
  alias Zaq.TestSupport.OntologyFake.Repo, as: FakeRepo

  test "fake repo helpers return deterministic records" do
    channel = FakeRepo.get(Channel, "chan-1")
    assert channel.id == "chan-1"
    assert channel.platform == "slack"

    assert %{id: "x"} = FakeRepo.get(:unknown_schema, "x")
    assert %{id: "x"} = FakeRepo.preload(%{id: "x"}, [:ignored])
  end

  test "businesses supports list/get/get_by_slug/create/update/delete" do
    assert [%Business{name: "Acme Corp"}] = Businesses.list()
    assert %Business{id: "b1", name: "Business b1"} = Businesses.get("b1")
    assert %Business{slug: "acme"} = Businesses.get_by_slug("default")

    assert {:ok, %Business{id: "biz-new", name: "New Biz"}} =
             Businesses.create(%{"name" => "New Biz", "slug" => "new-biz"})

    assert {:error, changeset} = Businesses.create(%{"slug" => "missing-name"})
    refute changeset.valid?

    assert {:ok, %Business{name: "Changed"}} =
             Businesses.update(%Business{}, %{"name" => "Changed"})

    assert {:ok, :deleted} = Businesses.delete(%Business{id: "ok"})

    assert {:error, delete_changeset} = Businesses.delete(%{id: "err-delete"})
    refute delete_changeset.valid?
  end

  test "divisions/departments/teams CRUD fakes" do
    assert %Division{id: "d1"} = Divisions.get("d1")
    assert {:ok, %Division{id: "div-new"}} = Divisions.create(%{"name" => "Ops"})
    assert {:ok, %Division{name: "Ops2"}} = Divisions.update(%Division{}, %{"name" => "Ops2"})
    assert {:ok, :deleted} = Divisions.delete(%Division{})

    assert %Department{id: "dept-1"} = Departments.get("dept-1")
    assert {:ok, %Department{id: "dept-new"}} = Departments.create(%{"name" => "Platform"})

    assert {:ok, %Department{name: "Platform2"}} =
             Departments.update(%Department{}, %{"name" => "Platform2"})

    assert {:ok, :deleted} = Departments.delete(%Department{})

    assert %Team{id: "team-1"} = Teams.get("team-1")
    assert {:ok, %Team{id: "team-new"}} = Teams.create(%{"name" => "Enablement"})
    assert {:ok, %Team{name: "Enablement2"}} = Teams.update(%Team{}, %{"name" => "Enablement2"})
    assert {:ok, :deleted} = Teams.delete(%Team{})
  end

  test "team member helper covers success and error branches" do
    assert {:ok, %TeamMember{id: "tm-1", team_id: "team-1"}} =
             Teams.add_member(%{team_id: "team-1", person_id: "person-1", role_in_team: "Lead"})

    assert {:error, changeset} = Teams.add_member(%{team_id: "error", person_id: "person-1"})
    refute changeset.valid?

    assert {:ok, :removed} = Teams.remove_member("team-1", "person-1")
    assert {:error, :cannot_remove} = Teams.remove_member("error", "person-1")
  end

  test "people helpers cover create/update/channels/preferred channel" do
    assert [%{id: "person-1"}] = People.list_active()
    assert %{id: "person-1"} = People.get("person-1")
    assert %{preferred_channel: %{platform: "slack"}} = People.get_with_channels("person-1")

    assert [%Channel{id: "chan-1"}, %Channel{id: "chan-2"}] = People.list_channels("person-1")

    person = People.get("person-1")

    assert {:ok, %{preferred_channel_id: "chan-2"}} =
             People.set_preferred_channel(person, "chan-2")

    assert {:error, changeset} = People.set_preferred_channel(person, "bad")
    refute changeset.valid?

    assert {:ok, %{id: "person-new", full_name: "Bob"}} =
             People.create(%{"full_name" => "Bob", "email" => "bob@example.test"})

    assert {:error, invalid_cs} = People.create(%{"email" => "missing-name@example.test"})
    refute invalid_cs.valid?

    assert {:ok, %{full_name: "Alice Updated"}} =
             People.update(person, %{"full_name" => "Alice Updated"})

    assert {:ok, :deleted} = People.delete(person)

    assert {:ok, %Channel{id: "chan-new", platform: "slack"}} =
             People.add_channel(%{"platform" => "slack", "person_id" => "person-1"})

    assert {:ok, %Channel{channel_identifier: "@alice2"}} =
             People.update_channel(%Channel{}, %{"channel_identifier" => "@alice2"})

    assert {:ok, :deleted} = People.delete_channel(%Channel{})
  end

  test "knowledge domain helpers cover create and error branches" do
    assert [%{id: "kd-1", name: "Billing"}] = KnowledgeDomains.list_by_business("biz-1")
    assert %{id: "kd-2", name: "Domain kd-2"} = KnowledgeDomains.get("kd-2")

    assert {:ok, %{id: "kd-new", name: "Security", keywords: ["soc2"]}} =
             KnowledgeDomains.create(%{"name" => "Security", "keywords" => ["soc2"]})

    assert {:error, changeset} = KnowledgeDomains.create(%{"description" => "missing name"})
    refute changeset.valid?

    assert {:ok, %{description: "New desc"}} =
             KnowledgeDomains.update(%KnowledgeDomain{}, %{"description" => "New desc"})

    assert {:ok, :deleted} = KnowledgeDomains.delete(%{})
  end
end
