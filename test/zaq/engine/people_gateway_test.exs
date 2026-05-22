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

  # ── :not_found branches ───────────────────────────────────────────────────

  test "dispatch returns :not_found for person operations when person is missing" do
    missing = -1
    assert {:error, :not_found} = PeopleGateway.dispatch(:get, %{id: missing})
    assert {:error, :not_found} = PeopleGateway.dispatch(:update, %{id: missing, attrs: %{}})
    assert {:error, :not_found} = PeopleGateway.dispatch(:delete, %{id: missing})

    assert {:error, :not_found} =
             PeopleGateway.dispatch(:assign_team, %{person_id: missing, team_id: 1})

    assert {:error, :not_found} =
             PeopleGateway.dispatch(:unassign_team, %{person_id: missing, team_id: 1})
  end

  test "dispatch returns :not_found for team operations when team is missing" do
    missing = -1
    assert {:error, :not_found} = PeopleGateway.dispatch(:get_team, %{id: missing})
    assert {:error, :not_found} = PeopleGateway.dispatch(:update_team, %{id: missing, attrs: %{}})
    assert {:error, :not_found} = PeopleGateway.dispatch(:delete_team, %{id: missing})
  end

  test "dispatch(:update_channel) returns :not_found for missing channel" do
    assert {:error, :not_found} = PeopleGateway.dispatch(:update_channel, %{id: -1, attrs: %{}})
  end

  test "dispatch(:delete_channel) returns :not_found for missing channel" do
    assert {:error, :not_found} = PeopleGateway.dispatch(:delete_channel, %{id: -1})
  end

  # ── update_channel happy path ─────────────────────────────────────────────

  test "dispatch(:update_channel) updates the channel identifier" do
    ts = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{"full_name" => "Chan Owner #{ts}", "email" => "co#{ts}@example.com"})

    {:ok, channel} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "slack",
        "channel_identifier" => "@before-#{ts}"
      })

    # attrs must use atom keys: People.update_channel merges an atom-keyed
    # :last_interaction_at, so a string-keyed map would produce mixed keys
    # that Ecto.Changeset.cast/3 rejects.
    assert {:ok, updated} =
             PeopleGateway.dispatch(:update_channel, %{
               id: channel.id,
               attrs: %{channel_identifier: "@after-#{ts}"}
             })

    assert updated.channel_identifier == "@after-#{ts}"
  end

  # ── normalize_id edge cases ───────────────────────────────────────────────

  test "dispatch(:get) accepts a binary string person ID" do
    ts = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{"full_name" => "StringID #{ts}", "email" => "sid#{ts}@example.com"})

    assert {:ok, found} = PeopleGateway.dispatch(:get, %{id: to_string(person.id)})
    assert found.id == person.id
  end

  test "dispatch(:get) handles nil ID via the catch-all normalize_id clause" do
    assert {:error, :not_found} = PeopleGateway.dispatch(:get, %{id: nil})
  end
end
