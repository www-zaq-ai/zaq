defmodule Zaq.Engine.PeopleGatewayTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.PeopleGateway

  test "dispatch(:create) creates a person" do
    attrs = %{"full_name" => "Gateway Person", "email" => "gateway@example.com"}

    assert {:ok, person} = PeopleGateway.dispatch(:create, %{attrs: attrs})
    assert person.full_name == "Gateway Person"
  end

  test "dispatch(:bulk_delete) deletes selected people" do
    {:ok, p1} = People.create_person(%{"full_name" => "Delete A", "email" => "del-a@example.com"})
    {:ok, p2} = People.create_person(%{"full_name" => "Delete B", "email" => "del-b@example.com"})

    assert {:ok, %{deleted_count: 2, failed_ids: []}} =
             PeopleGateway.dispatch(:bulk_delete, %{person_ids: [p1.id, p2.id]})
  end

  test "dispatch/2 returns unsupported error for unknown operation" do
    assert {:error, :unsupported_people_operation} = PeopleGateway.dispatch(:unknown, %{})
  end
end
