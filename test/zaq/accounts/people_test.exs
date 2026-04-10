defmodule Zaq.Accounts.PeopleTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp person_attrs(overrides \\ %{}) do
    Map.merge(
      %{full_name: "Jane Smith", email: "jane@example.com", role: "Engineer", status: "active"},
      overrides
    )
  end

  defp create_person(attrs \\ %{}) do
    {:ok, person} = People.create_person(person_attrs(attrs))
    person
  end

  defp channel_attrs(person_id, overrides \\ %{}) do
    Map.merge(
      %{"platform" => "slack", "channel_identifier" => "@jane", "person_id" => person_id},
      overrides
    )
  end

  defp add_channel(person_id, attrs \\ %{}) do
    {:ok, channel} = People.add_channel(channel_attrs(person_id, attrs))
    channel
  end

  # ── People ───────────────────────────────────────────────────────────────

  describe "list_people/0" do
    test "returns empty list when no people exist" do
      assert People.list_people() == []
    end

    test "returns people ordered by full_name" do
      create_person(%{full_name: "Zara", email: "zara@example.com"})
      create_person(%{full_name: "Alice", email: "alice@example.com"})
      create_person(%{full_name: "Mike", email: "mike@example.com"})

      names = People.list_people() |> Enum.map(& &1.full_name)
      assert names == ["Alice", "Mike", "Zara"]
    end

    test "preloads channels with each person" do
      person = create_person(%{email: nil})
      add_channel(person.id)

      [loaded] = People.list_people()
      assert length(loaded.channels) == 1
    end
  end

  describe "create_person/1" do
    test "creates person with valid attrs" do
      assert {:ok, person} = People.create_person(person_attrs())
      assert person.full_name == "Jane Smith"
      assert person.status == "active"
    end

    test "fails when full_name is missing" do
      assert {:error, changeset} = People.create_person(%{email: "x@example.com"})
      assert "can't be blank" in errors_on(changeset).full_name
    end

    test "fails with duplicate email" do
      create_person()
      assert {:error, changeset} = People.create_person(person_attrs())
      assert "has already been taken" in errors_on(changeset).email
    end

    test "fails with invalid status" do
      assert {:error, changeset} = People.create_person(person_attrs(%{status: "banned"}))
      assert errors_on(changeset).status != []
    end

    test "auto-links email channel when email is present" do
      {:ok, person} = People.create_person(person_attrs())
      channels = People.list_person_channels(person.id)
      assert length(channels) == 1
      assert hd(channels).platform == "email"
      assert hd(channels).channel_identifier == "jane@example.com"
      assert hd(channels).weight == 0
    end

    test "does not auto-link email channel when email is nil" do
      {:ok, person} = People.create_person(person_attrs(%{email: nil}))
      assert People.list_person_channels(person.id) == []
    end
  end

  describe "get_person!/1" do
    test "returns the person" do
      person = create_person()
      assert People.get_person!(person.id).id == person.id
    end

    test "raises on missing id" do
      assert_raise Ecto.NoResultsError, fn -> People.get_person!(0) end
    end
  end

  describe "get_person_with_channels!/1" do
    test "preloads channels ordered by weight" do
      person = create_person()
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@example.com"})

      loaded = People.get_person_with_channels!(person.id)
      weights = Enum.map(loaded.channels, & &1.weight)
      assert weights == Enum.sort(weights)
    end

    test "weight 0 is first" do
      person = create_person()
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@example.com"})

      loaded = People.get_person_with_channels!(person.id)
      assert hd(loaded.channels).weight == 0
    end
  end

  describe "update_person/2" do
    test "updates fields" do
      person = create_person()
      assert {:ok, updated} = People.update_person(person, %{full_name: "Jane Doe"})
      assert updated.full_name == "Jane Doe"
    end

    test "validates status inclusion" do
      person = create_person()
      assert {:error, changeset} = People.update_person(person, %{status: "unknown"})
      assert errors_on(changeset).status != []
    end

    test "auto-links email channel when email is set for the first time" do
      person = create_person(%{email: nil})
      assert People.list_person_channels(person.id) == []

      {:ok, updated} = People.update_person(person, %{email: "new@example.com"})
      channels = People.list_person_channels(updated.id)
      assert length(channels) == 1
      assert hd(channels).platform == "email"
      assert hd(channels).channel_identifier == "new@example.com"
    end

    test "does not duplicate email channel when email is unchanged" do
      person = create_person()
      assert length(People.list_person_channels(person.id)) == 1

      {:ok, _} = People.update_person(person, %{full_name: "Jane Doe"})
      assert length(People.list_person_channels(person.id)) == 1
    end
  end

  describe "delete_person/1" do
    test "removes the person" do
      person = create_person()
      assert {:ok, _} = People.delete_person(person)
      assert_raise Ecto.NoResultsError, fn -> People.get_person!(person.id) end
    end
  end

  # ── Channels ─────────────────────────────────────────────────────────────

  describe "add_channel/1" do
    test "first channel gets weight 0" do
      person = create_person(%{email: nil})
      {:ok, channel} = People.add_channel(channel_attrs(person.id))
      assert channel.weight == 0
    end

    test "subsequent channels auto-increment weight" do
      person = create_person(%{email: nil})
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})

      {:ok, second} =
        People.add_channel(
          channel_attrs(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})
        )

      assert second.weight == 1
    end

    test "accepts all valid platforms" do
      person = create_person()

      for {platform, identifier} <- [
            {"mattermost", "@mm"},
            {"slack", "@slack"},
            {"microsoft_teams", "@teams"},
            {"whatsapp", "+1234567890"},
            {"email", "j@example.com"}
          ] do
        p2 = create_person(%{full_name: "#{platform} user", email: "#{platform}@test.com"})

        assert {:ok, _} =
                 People.add_channel(%{
                   "platform" => platform,
                   "channel_identifier" => identifier,
                   "person_id" => p2.id
                 })
      end

      _ = person
    end

    test "fails with invalid platform" do
      person = create_person()

      assert {:error, changeset} =
               People.add_channel(channel_attrs(person.id, %{"platform" => "fax"}))

      assert errors_on(changeset).platform != []
    end
  end

  describe "get_preferred_channel/1" do
    test "returns weight-0 channel" do
      person = create_person(%{email: nil})
      first = add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})

      preferred = People.get_preferred_channel(person.id)
      assert preferred.id == first.id
      assert preferred.weight == 0
    end

    test "returns nil when no channels" do
      person = create_person(%{email: nil})
      assert People.get_preferred_channel(person.id) == nil
    end
  end

  describe "update_channel/2" do
    test "updates channel_identifier" do
      person = create_person()
      channel = add_channel(person.id)
      assert {:ok, updated} = People.update_channel(channel, %{channel_identifier: "@new_jane"})
      assert updated.channel_identifier == "@new_jane"
    end
  end

  describe "delete_channel/1" do
    test "removes the channel" do
      person = create_person(%{email: nil})
      channel = add_channel(person.id)
      assert {:ok, _} = People.delete_channel(channel)
      assert People.list_person_channels(person.id) == []
    end
  end

  describe "swap_channel_weights/2" do
    test "exchanges weights atomically" do
      person = create_person(%{email: nil})
      a = add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      b = add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})

      assert {:ok, _} = People.swap_channel_weights(a, b)

      channels = People.list_person_channels(person.id)
      [first, second] = channels

      assert first.id == b.id
      assert first.weight == 0
      assert second.id == a.id
      assert second.weight == 1
    end

    test "weight 0 stays preferred after swap (it moves to the other channel)" do
      person = create_person(%{email: nil})
      a = add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      b = add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})

      People.swap_channel_weights(a, b)
      preferred = People.get_preferred_channel(person.id)
      assert preferred.id == b.id
    end
  end

  describe "record_interaction/1" do
    test "updates last_interaction_at to now" do
      person = create_person()
      channel = add_channel(person.id)
      assert is_nil(channel.last_interaction_at)

      assert {:ok, updated} = People.record_interaction(channel)
      refute is_nil(updated.last_interaction_at)
    end
  end

  # ── list_incomplete ───────────────────────────────────────────────────────

  describe "list_incomplete/0" do
    test "returns only people with incomplete: true" do
      incomplete = create_person(%{full_name: "No Phone", email: "nophone@example.com"})

      {:ok, complete} =
        People.create_person(%{
          full_name: "Full Person",
          email: "fullperson@example.com",
          phone: "+10000000001"
        })

      ids = People.list_incomplete() |> Enum.map(& &1.id)
      assert incomplete.id in ids
      refute complete.id in ids
    end
  end

  # ── filter_people ─────────────────────────────────────────────────────────

  describe "filter_people/2" do
    test "empty filters returns all people and correct total" do
      create_person(%{full_name: "Filter Alpha", email: "filter.alpha@example.com"})
      create_person(%{full_name: "Filter Beta", email: "filter.beta@example.com"})

      {people, total} = People.filter_people(%{})
      assert total >= 2
      assert length(people) >= 2
    end

    test "filters by name (case-insensitive)" do
      create_person(%{full_name: "Unique Xname", email: "xname@example.com"})
      create_person(%{full_name: "Other Person", email: "other@example.com"})

      {people, total} = People.filter_people(%{"name" => "xname"})
      assert total == 1
      assert hd(people).full_name == "Unique Xname"
    end

    test "filters by email" do
      create_person(%{full_name: "Email Guy", email: "uniqueemail99@example.com"})

      {people, _} = People.filter_people(%{"email" => "uniqueemail99"})
      assert length(people) == 1
      assert hd(people).email == "uniqueemail99@example.com"
    end

    test "filters by phone" do
      {:ok, _} =
        People.create_person(%{
          full_name: "Phone Guy",
          email: "phonefilter@example.com",
          phone: "+19876543210"
        })

      {people, _} = People.filter_people(%{"phone" => "9876543210"})
      assert Enum.any?(people, &(&1.phone == "+19876543210"))
    end

    test "filters complete people" do
      create_person(%{full_name: "Inc Person Filter", email: "incpf@example.com"})

      {:ok, complete} =
        People.create_person(%{
          full_name: "Complete Person Filter",
          email: "cpf@example.com",
          phone: "+10000000002"
        })

      {people, _} = People.filter_people(%{"complete" => "complete"})
      ids = Enum.map(people, & &1.id)
      assert complete.id in ids
      refute Enum.any?(people, &(&1.incomplete == true))
    end

    test "filters incomplete people" do
      incomplete = create_person(%{full_name: "Inc Only Filter", email: "inconly@example.com"})

      {:ok, complete} =
        People.create_person(%{
          full_name: "Complete Only Filter",
          email: "conly@example.com",
          phone: "+10000000003"
        })

      {people, _} = People.filter_people(%{"complete" => "incomplete"})
      ids = Enum.map(people, & &1.id)
      assert incomplete.id in ids
      refute complete.id in ids
    end

    test "filters by team_id" do
      {:ok, team} = People.create_team(%{name: "Filter Team #{System.unique_integer()}"})
      in_team = create_person(%{full_name: "In Team", email: "inteam@example.com"})
      out_team = create_person(%{full_name: "Out Team", email: "outteam@example.com"})
      People.assign_team(in_team, team.id)

      {people, _} = People.filter_people(%{"team_id" => to_string(team.id)})
      ids = Enum.map(people, & &1.id)
      assert in_team.id in ids
      refute out_team.id in ids
    end

    test "paginates results" do
      for i <- 1..5 do
        create_person(%{full_name: "Paginate #{i}", email: "pag#{i}@example.com"})
      end

      {page1, total} = People.filter_people(%{"name" => "Paginate"}, page: 1, per_page: 3)
      {page2, _} = People.filter_people(%{"name" => "Paginate"}, page: 2, per_page: 3)

      assert total == 5
      assert length(page1) == 3
      assert length(page2) == 2
      assert Enum.map(page1, & &1.id) != Enum.map(page2, & &1.id)
    end
  end

  # ── match_by_channel ──────────────────────────────────────────────────────

  describe "match_by_channel/2" do
    test "returns person when channel exists" do
      person = create_person()
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@match_me"})

      assert {:ok, found} = People.match_by_channel("slack", "@match_me")
      assert found.id == person.id
    end

    test "returns error when no channel matches" do
      assert {:error, :not_found} = People.match_by_channel("slack", "@ghost")
    end

    test "returns error for empty channel_identifier" do
      assert {:error, :not_found} = People.match_by_channel("slack", "")
    end
  end

  # ── match_person ──────────────────────────────────────────────────────────

  describe "match_person/1" do
    test "matches by email" do
      person = create_person(%{full_name: "Match Email", email: "matchemail@example.com"})
      assert {:ok, found} = People.match_person(%{"email" => "matchemail@example.com"})
      assert found.id == person.id
    end

    test "matches by phone when email missing" do
      {:ok, person} =
        People.create_person(%{
          full_name: "Match Phone",
          email: "matchphone@example.com",
          phone: "+15559990001"
        })

      assert {:ok, found} = People.match_person(%{"phone" => "+15559990001"})
      assert found.id == person.id
    end

    test "matches by channel when email/phone missing" do
      person = create_person()
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@chan_match"})

      assert {:ok, found} =
               People.match_person(%{"platform" => "slack", "channel_id" => "@chan_match"})

      assert found.id == person.id
    end

    test "returns error when nothing matches" do
      assert {:error, :not_found} =
               People.match_person(%{
                 "email" => "nobody@example.com",
                 "phone" => "+10000000000",
                 "platform" => "slack",
                 "channel_id" => "@nobody"
               })
    end
  end

  # ── find_or_create_from_channel ───────────────────────────────────────────

  describe "find_or_create_from_channel/2" do
    test "creates a partial person and links channel on miss" do
      attrs = %{
        "channel_id" => "@new_bot",
        "display_name" => "New Bot",
        "email" => nil,
        "phone" => nil
      }

      assert {:ok, person} = People.find_or_create_from_channel("slack", attrs)
      assert person.full_name == "New Bot"
      assert person.incomplete == true
      assert Enum.any?(person.channels, &(&1.channel_identifier == "@new_bot"))
    end

    test "uses channel_id as full_name when display_name absent" do
      assert {:ok, person} =
               People.find_or_create_from_channel("slack", %{"channel_id" => "@fallback_id"})

      assert person.full_name == "@fallback_id"
    end

    test "returns existing person on match and links channel" do
      existing = create_person(%{full_name: "Existing", email: "existing@example.com"})

      assert {:ok, found} =
               People.find_or_create_from_channel("slack", %{
                 "email" => "existing@example.com",
                 "channel_id" => "@existing_chan"
               })

      assert found.id == existing.id
      assert Enum.any?(found.channels, &(&1.channel_identifier == "@existing_chan"))
    end

    test "backfills email onto existing person if missing" do
      {:ok, person} = People.create_person(%{full_name: "No Email Yet", incomplete: true})

      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@backfill_me"})

      assert {:ok, updated} =
               People.find_or_create_from_channel("slack", %{
                 "channel_id" => "@backfill_me",
                 "email" => "backfilled@example.com"
               })

      assert updated.id == person.id
      assert updated.email == "backfilled@example.com"
    end
  end

  # ── merge_persons ─────────────────────────────────────────────────────────

  describe "merge_persons/2" do
    test "transfers channels from loser to survivor" do
      survivor = create_person(%{full_name: "Survivor", email: "survivor@example.com"})
      loser = create_person(%{full_name: "Loser", email: "loser@example.com"})

      loser_chan =
        add_channel(loser.id, %{"platform" => "slack", "channel_identifier" => "@loser"})

      survivor = People.get_person_with_channels!(survivor.id)
      loser = People.get_person_with_channels!(loser.id)

      assert {:ok, updated} = People.merge_persons(survivor, loser)
      chan_ids = Enum.map(updated.channels, & &1.id)
      assert loser_chan.id in chan_ids
    end

    test "deletes the loser after merge" do
      survivor = create_person(%{full_name: "Surv2", email: "surv2@example.com"})
      loser = create_person(%{full_name: "Loser2", email: "loser2@example.com"})

      survivor = People.get_person_with_channels!(survivor.id)
      loser = People.get_person_with_channels!(loser.id)
      loser_id = loser.id

      assert {:ok, _} = People.merge_persons(survivor, loser)
      assert_raise Ecto.NoResultsError, fn -> People.get_person!(loser_id) end
    end

    test "unions team_ids from both persons" do
      {:ok, team_a} = People.create_team(%{name: "Merge TeamA #{System.unique_integer()}"})
      {:ok, team_b} = People.create_team(%{name: "Merge TeamB #{System.unique_integer()}"})

      survivor = create_person(%{full_name: "Team Surv", email: "tsurv@example.com"})
      loser = create_person(%{full_name: "Team Loser", email: "tloser@example.com"})

      {:ok, survivor} = People.assign_team(survivor, team_a.id)
      {:ok, loser} = People.assign_team(loser, team_b.id)

      survivor = People.get_person_with_channels!(survivor.id)
      loser = People.get_person_with_channels!(loser.id)

      assert {:ok, updated} = People.merge_persons(survivor, loser)
      assert team_a.id in updated.team_ids
      assert team_b.id in updated.team_ids
    end

    test "does not duplicate shared team_ids" do
      {:ok, team} = People.create_team(%{name: "Shared Team #{System.unique_integer()}"})

      survivor = create_person(%{full_name: "Shared Surv", email: "ssurv@example.com"})
      loser = create_person(%{full_name: "Shared Loser", email: "sloser@example.com"})

      {:ok, survivor} = People.assign_team(survivor, team.id)
      {:ok, loser} = People.assign_team(loser, team.id)

      survivor = People.get_person_with_channels!(survivor.id)
      loser = People.get_person_with_channels!(loser.id)

      assert {:ok, updated} = People.merge_persons(survivor, loser)
      assert Enum.count(updated.team_ids, &(&1 == team.id)) == 1
    end

    test "backfills email from loser onto survivor if missing" do
      {:ok, survivor} = People.create_person(%{full_name: "No Email Surv", incomplete: true})
      loser = create_person(%{full_name: "Has Email", email: "hazemail@example.com"})

      survivor = People.get_person_with_channels!(survivor.id)
      loser = People.get_person_with_channels!(loser.id)

      assert {:ok, updated} = People.merge_persons(survivor, loser)
      assert updated.email == "hazemail@example.com"
    end
  end

  # ── Teams ─────────────────────────────────────────────────────────────────

  defp team_attrs(overrides) do
    Map.merge(%{name: "Team #{System.unique_integer([:positive])}"}, overrides)
  end

  defp create_team(attrs \\ %{}) do
    {:ok, team} = People.create_team(team_attrs(attrs))
    team
  end

  describe "list_teams/0" do
    test "returns teams ordered by name" do
      create_team(%{name: "Zeta"})
      create_team(%{name: "Alpha"})

      names = People.list_teams() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "create_team/1" do
    test "creates a team with valid attrs" do
      assert {:ok, team} = People.create_team(%{name: "Engineering"})
      assert team.name == "Engineering"
    end

    test "fails when name is blank" do
      assert {:error, changeset} = People.create_team(%{name: ""})
      assert errors_on(changeset).name != []
    end

    test "fails with duplicate name" do
      create_team(%{name: "Unique Team"})
      assert {:error, changeset} = People.create_team(%{name: "Unique Team"})
      assert errors_on(changeset).name != []
    end
  end

  describe "update_team/2" do
    test "updates team name" do
      team = create_team()
      assert {:ok, updated} = People.update_team(team, %{name: "Renamed Team"})
      assert updated.name == "Renamed Team"
    end
  end

  describe "delete_team/1" do
    test "removes the team" do
      team = create_team()
      assert {:ok, _} = People.delete_team(team)
      assert_raise Ecto.NoResultsError, fn -> People.get_team!(team.id) end
    end

    test "removes team_id from all assigned people" do
      team = create_team()
      person = create_person(%{full_name: "Has Team", email: "hasteam@example.com"})
      {:ok, person} = People.assign_team(person, team.id)
      assert team.id in person.team_ids

      People.delete_team(team)

      updated = People.get_person!(person.id)
      refute team.id in updated.team_ids
    end
  end

  describe "assign_team/2" do
    test "adds team_id to person" do
      team = create_team()
      person = create_person(%{full_name: "Assignee", email: "assignee@example.com"})

      assert {:ok, updated} = People.assign_team(person, team.id)
      assert team.id in updated.team_ids
    end

    test "is idempotent — does not duplicate" do
      team = create_team()
      person = create_person(%{full_name: "Idempotent", email: "idempotent@example.com"})

      {:ok, once} = People.assign_team(person, team.id)
      {:ok, twice} = People.assign_team(once, team.id)

      assert Enum.count(twice.team_ids, &(&1 == team.id)) == 1
    end
  end

  describe "unassign_team/2" do
    test "removes team_id from person" do
      team = create_team()
      person = create_person(%{full_name: "Unassignee", email: "unassignee@example.com"})
      {:ok, assigned} = People.assign_team(person, team.id)

      assert {:ok, updated} = People.unassign_team(assigned, team.id)
      refute team.id in updated.team_ids
    end
  end

  # ── find_or_create_from_channel — email platform branches ──────────

  describe "find_or_create_from_channel/2 email platform" do
    test "does not add a duplicate email channel when platform is already email" do
      # When the platform IS email, maybe_link_email_channel/3 must be a no-op
      # (no second channel should be created for the same identifier).
      attrs = %{"channel_id" => "em@example.com", "email" => "em@example.com"}

      assert {:ok, person} = People.find_or_create_from_channel("email", attrs)

      channels = People.list_person_channels(person.id)
      email_channels = Enum.filter(channels, &(&1.channel_identifier == "em@example.com"))
      assert length(email_channels) == 1
    end

    test "backfills display_name onto existing person whose full_name looks like an email address" do
      # insert_partial_person seeds full_name from channel_identifier (an email address).
      # backfill_person treats that as absent so a real display_name can replace it.
      attrs_initial = %{"channel_id" => "bot@company.com", "email" => "bot@company.com"}
      {:ok, person} = People.find_or_create_from_channel("slack", attrs_initial)

      assert person.full_name == "bot@company.com"

      attrs_with_name = %{
        "channel_id" => "bot@company.com",
        "email" => "bot@company.com",
        "display_name" => "Real Bot Name"
      }

      {:ok, updated} = People.find_or_create_from_channel("slack", attrs_with_name)
      assert updated.id == person.id
      assert updated.full_name == "Real Bot Name"
    end
  end

  # ── get_person/1 nil guard ─────────────────────────────────────────

  describe "get_person/1" do
    test "returns nil when id is nil" do
      assert People.get_person(nil) == nil
    end

    test "returns nil for unknown id" do
      assert People.get_person(0) == nil
    end

    test "returns person when found" do
      person = create_person()
      assert People.get_person(person.id).id == person.id
    end
  end

  # ── get_person_with_channels/1 ────────────────────────────────────

  describe "get_person_with_channels/1" do
    test "returns nil for unknown id" do
      assert People.get_person_with_channels(0) == nil
    end

    test "returns person with channels when found" do
      person = create_person(%{email: nil})
      add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@gc_test"})
      loaded = People.get_person_with_channels(person.id)
      assert loaded.id == person.id
      assert length(loaded.channels) == 1
    end
  end

  # ── search_people/3 ───────────────────────────────────────────────

  describe "search_people/3" do
    test "returns people matching query by full_name" do
      person = create_person(%{full_name: "Searchable Name XYZ", email: "sxyz@example.com"})

      results = People.search_people("Searchable Name XYZ")
      assert Enum.any?(results, &(&1.id == person.id))
    end

    test "returns people matching query by email" do
      person = create_person(%{full_name: "Email Searcher", email: "searchemail99@example.com"})

      results = People.search_people("searchemail99")
      assert Enum.any?(results, &(&1.id == person.id))
    end

    test "excludes ids passed in exclude_ids" do
      person = create_person(%{full_name: "Excludable Person", email: "exclude_me@example.com"})

      results = People.search_people("Excludable", [person.id])
      refute Enum.any?(results, &(&1.id == person.id))
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        create_person(%{full_name: "LimitSearch#{i}", email: "ls#{i}@example.com"})
      end

      results = People.search_people("LimitSearch", [], 3)
      assert length(results) <= 3
    end

    test "returns empty list when no match" do
      assert People.search_people("NoMatchXYZABC123") == []
    end
  end
end
