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
      person = create_person()
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
      person = create_person()
      {:ok, channel} = People.add_channel(channel_attrs(person.id))
      assert channel.weight == 0
    end

    test "subsequent channels auto-increment weight" do
      person = create_person()
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
               People.add_channel(channel_attrs(person.id, %{"platform" => "telegram"}))

      assert errors_on(changeset).platform != []
    end
  end

  describe "get_preferred_channel/1" do
    test "returns weight-0 channel" do
      person = create_person()
      first = add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})

      preferred = People.get_preferred_channel(person.id)
      assert preferred.id == first.id
      assert preferred.weight == 0
    end

    test "returns nil when no channels" do
      person = create_person()
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
      person = create_person()
      channel = add_channel(person.id)
      assert {:ok, _} = People.delete_channel(channel)
      assert People.list_person_channels(person.id) == []
    end
  end

  describe "swap_channel_weights/2" do
    test "exchanges weights atomically" do
      person = create_person()
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
      person = create_person()
      a = add_channel(person.id, %{"platform" => "slack", "channel_identifier" => "@slack"})
      b = add_channel(person.id, %{"platform" => "email", "channel_identifier" => "j@x.com"})

      People.swap_channel_weights(a, b)
      preferred = People.get_preferred_channel(person.id)
      assert preferred.id == b.id
    end
  end
end
