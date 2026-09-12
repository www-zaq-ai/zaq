defmodule Zaq.Accounts.ChannelIdentityTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, Person, PersonChannel}

  @duplicate "This channel identifier is already assigned."

  test "profile updates and unchanged canonical email do not repair a missing email channel" do
    {:ok, person} = People.create_person(%{full_name: "Original", email: "missing@example.com"})
    [channel] = People.list_person_channels(person.id)
    {:ok, _} = People.delete_channel(channel)

    for attrs <- [%{full_name: "Renamed"}, %{"email" => " MISSING@EXAMPLE.COM "}] do
      assert {:ok, updated} = People.update_person(person, attrs)
      assert updated.email == person.email
      assert People.list_person_channels(person.id) == []
    end

    {:ok, owner} = People.create_person(%{full_name: "External"})

    {:ok, owned} =
      People.add_channel(%{
        person_id: owner.id,
        platform: "email",
        channel_identifier: person.email
      })

    assert {:ok, updated} =
             People.update_person(person, %{"role" => "Colleague", :phone => "123"})

    assert updated.phone == "123"
    assert updated.role == "Colleague"
    assert People.get_channel(owned.id) == owned
    assert People.list_person_channels(person.id) == []
  end

  test "actual email changes link once while nil and blank clear without removing prior identities" do
    {:ok, person} = People.create_person(%{full_name: "Person", email: "before@example.com"})
    assert {:ok, changed} = People.update_person(person, %{"email" => " AFTER@example.com "})
    channels = People.list_person_channels(person.id)

    assert Enum.map(channels, & &1.channel_identifier) == [
             "before@example.com",
             "after@example.com"
           ]

    for clear <- [nil, "", " \t"] do
      assert {:ok, cleared} = People.update_person(changed, %{email: clear})
      assert cleared.email == nil
      assert People.list_person_channels(person.id) == channels
    end
  end

  test "discovery links each distinct required email only once when backfilling" do
    {:ok, person} = People.create_person(%{full_name: "Person", phone: "123"})
    handler = {__MODULE__, self()}
    owner = self()

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and metadata[:source] == "channels" and
             String.starts_with?(metadata.query, "SELECT") and
             metadata.params == [person.id, "email", "incoming@example.com"] do
          send(owner, :email_link_lookup)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, found} =
             People.find_or_create_from_channel(:telegram, %{
               "channel_id" => "incoming",
               :email => " INCOMING@example.com ",
               :phone => "123"
             })

    assert found.id == person.id
    assert found.email == "incoming@example.com"
    assert length(found.channels) == 2
    assert_received :email_link_lookup
    refute_received :email_link_lookup
  end

  test "email discovery retains distinct incoming identity and incoming profile email" do
    assert {:ok, found} =
             People.find_or_create_from_channel("email:imap", %{
               channel_id: " CHANNEL@example.com ",
               email: " PROFILE@example.com "
             })

    assert found.email == "profile@example.com"

    assert Enum.sort(Enum.map(found.channels, & &1.channel_identifier)) ==
             ["channel@example.com", "profile@example.com"]
  end

  test "discovery profile backfill does not repair an unrelated stored email identity" do
    {:ok, person} =
      People.create_person(%{
        full_name: "stored@example.com",
        email: "stored@example.com",
        phone: "123"
      })

    [channel] = People.list_person_channels(person.id)
    {:ok, _} = People.delete_channel(channel)

    for incoming_email <- [nil, 123] do
      assert {:ok, found} =
               People.find_or_create_from_channel(:telegram, %{
                 channel_id: "stored-profile",
                 phone: person.phone,
                 display_name: "Incoming name",
                 email: incoming_email
               })

      assert found.id == person.id
      assert found.email == person.email
      assert found.full_name == "Incoming name"
      assert [%{platform: "telegram", channel_identifier: "stored-profile"}] = found.channels
    end
  end

  test "resource merge retains source channel order and records explicit channel edits as activity" do
    {:ok, person} = People.create_person(%{full_name: "Person"})
    {:ok, other} = People.create_person(%{full_name: "Other", email: "priority@example.com"})

    {:ok, old} =
      People.add_channel(%{
        person_id: person.id,
        platform: "telegram",
        channel_identifier: "old",
        last_interaction_at: ~U[2020-01-01 00:00:00Z]
      })

    assert {:ok, merged} =
             People.update_person_resource(
               person,
               %{},
               [
                 %{id: old.id, display_name: "Edited"},
                 %{platform: "telegram", channel_identifier: "z-first", weight: 99},
                 %{platform: "telegram", channel_identifier: "a-second"}
               ],
               %{merge_with_person_id: other.id, merge_precedence: "other"}
             )

    assert Enum.find(merged.channels, &(&1.channel_identifier == "z-first")).weight == 1
    assert Enum.find(merged.channels, &(&1.channel_identifier == "a-second")).weight == 2

    assert DateTime.compare(
             People.get_channel(old.id).last_interaction_at,
             old.last_interaction_at
           ) == :gt

    assert People.get_channel(old.id).weight == 0
  end

  test "explicit resource merge rolls back both participants when subsequent edits are invalid" do
    {:ok, person} = People.create_person(%{full_name: "Person"})
    {:ok, other} = People.create_person(%{full_name: "Other"})
    {:ok, outside} = People.create_person(%{full_name: "Outside"})

    {:ok, channel} =
      People.add_channel(%{
        person_id: outside.id,
        platform: "telegram",
        channel_identifier: "outside"
      })

    for {attrs, channels, reason} <- [
          {:invalid, [], :invalid_person_attrs},
          {%{}, :invalid, :invalid_channels},
          {%{}, [:invalid], :invalid_channel},
          {%{}, [%{id: channel.id, display_name: "Stolen"}], :channel_not_found}
        ] do
      assert {:error, ^reason} =
               People.update_person_resource(person, attrs, channels, %{
                 merge_with_person_id: other.id
               })

      assert People.get_person!(person.id) == person
      assert People.get_person!(other.id) == other
      assert People.get_channel(channel.id) == channel
    end
  end

  test "resource channel edits use current participant ownership and preserve their IDs" do
    {:ok, person} = People.create_person(%{full_name: "Person", email: "old@example.com"})
    {:ok, other} = People.create_person(%{full_name: "Other"})

    {:ok, channel} =
      People.add_channel(%{
        person_id: person.id,
        platform: "telegram",
        channel_identifier: "original"
      })

    {:ok, email} =
      People.add_channel(%{
        person_id: person.id,
        platform: "email",
        channel_identifier: "existing@example.com"
      })

    assert {:ok, merged} =
             People.update_person_resource(
               person,
               %{email: email.channel_identifier},
               [
                 %{
                   id: to_string(channel.id),
                   display_name: "Edited",
                   channel_identifier: "changed"
                 }
               ],
               %{merge_with_person_id: other.id}
             )

    assert People.get_channel(channel.id).display_name == "Edited"
    assert People.get_channel(channel.id).channel_identifier == "changed"
    assert People.get_channel(email.id).person_id == merged.id

    {:ok, next} = People.create_person(%{full_name: "Next"})

    assert {:ok, cleared} =
             People.update_person_resource(merged, %{email: nil}, [], %{
               merge_with_person_id: next.id
             })

    assert cleared.email == nil
  end

  test "discovery inside a caller transaction propagates conflicts without retrying aborted SQL" do
    {:ok, person} = People.create_person(%{full_name: "Person", email: "matched@example.com"})
    {:ok, owner} = People.create_person(%{full_name: "Owner"})

    {:ok, _} =
      People.add_channel(%{
        person_id: owner.id,
        platform: "telegram",
        channel_identifier: "nested"
      })

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert {:error, error} =
                        People.find_or_create_from_channel(:telegram, %{
                          email: person.email,
                          channel_id: "nested"
                        })

               assert errors_on(error).channel_identifier == [@duplicate]
             end)
  end

  test "resource email edit colliding with a merge participant succeeds and external conflicts roll back" do
    {:ok, person} = People.create_person(%{full_name: "Person", email: "before@example.com"})
    {:ok, other} = People.create_person(%{full_name: "Other", email: "participant@example.com"})

    assert {:ok, merged} =
             People.update_person_resource(person, %{email: " PARTICIPANT@example.com "}, [], %{
               merge_with_person_id: other.id
             })

    assert merged.email == "participant@example.com"
    assert Enum.count(merged.channels, &(&1.channel_identifier == "participant@example.com")) == 1

    {:ok, loser} = People.create_person(%{full_name: "Loser"})
    {:ok, outside} = People.create_person(%{full_name: "Outside", email: "outside@example.com"})

    assert {:error, _} =
             People.update_person_resource(loser, %{email: outside.email}, [], %{
               merge_with_person_id: merged.id,
               merge_precedence: "other"
             })

    assert People.get_person!(loser.id).id == loser.id
    assert People.get_person!(merged.id).email == merged.email
  end

  for precedence <- ["person", "other"] do
    test "resource profile edits override #{precedence} survivor selection but history stays original" do
      {:ok, person} =
        People.create_person(%{full_name: "Original participant", role: "Original role"})

      {:ok, other} = People.create_person(%{full_name: "Other survivor", role: "Other role"})

      assert {:ok, merged} =
               People.update_person_resource(
                 person,
                 %{full_name: "Edited participant", role: "Edited role", phone: "123"},
                 [],
                 %{merge_with_person_id: other.id, merge_precedence: unquote(precedence)}
               )

      assert merged.phone == "123"

      if unquote(precedence) == "person" do
        assert merged.id == person.id
        assert merged.full_name == "Edited participant"
        assert merged.role == "Edited role"
        assert [%{"id" => id, "label" => "Other survivor"}] = merged.merge_history
        assert id == other.id
      else
        assert merged.id == other.id
        assert merged.full_name == "Edited participant"
        assert merged.role == "Edited role"
        assert [%{"id" => id, "label" => "Original participant"}] = merged.merge_history
        assert id == person.id
      end
    end

    test "#{precedence} merge rejects an external channel owner without absorbing or changing anyone" do
      {:ok, person} = People.create_person(%{full_name: "Participant"})
      {:ok, other} = People.create_person(%{full_name: "Other"})
      {:ok, outside} = People.create_person(%{full_name: "External"})

      {:ok, channel} =
        People.add_channel(%{
          person_id: person.id,
          platform: "telegram",
          channel_identifier: "original"
        })

      {:ok, owned} =
        People.add_channel(%{
          person_id: outside.id,
          platform: "telegram",
          channel_identifier: "external"
        })

      assert {:error, error} =
               People.update_person_resource(
                 person,
                 %{full_name: "Changed"},
                 [%{id: channel.id, channel_identifier: "external"}],
                 %{merge_with_person_id: other.id, merge_precedence: unquote(precedence)}
               )

      assert errors_on(error).channel_identifier == [@duplicate]

      for original <- [person, other, outside],
          do: assert(People.get_person!(original.id) == original)

      assert People.get_channel(channel.id) == channel
      assert People.get_channel(owned.id) == owned
    end

    test "new channel insert after #{precedence} merge rejects an existing participant identity" do
      {:ok, person} = People.create_person(%{full_name: "Person"})
      {:ok, other} = People.create_person(%{full_name: "Other"})

      {:ok, original} =
        People.add_channel(%{
          person_id: other.id,
          platform: "telegram",
          channel_identifier: "participant",
          display_name: "Other channel"
        })

      assert {:error, error} =
               People.update_person_resource(
                 person,
                 %{full_name: "Updated"},
                 [
                   %{
                     platform: "telegram",
                     channel_identifier: "participant",
                     display_name: "Requested",
                     phone: "123"
                   }
                 ],
                 %{merge_with_person_id: other.id, merge_precedence: unquote(precedence)}
               )

      assert errors_on(error).channel_identifier == [@duplicate]
      assert People.get_person!(person.id) == person
      assert People.get_person!(other.id) == other
      assert People.get_channel(original.id) == original
    end

    test "#{precedence} merge applies nil edits and preserves omitted profile precedence" do
      {:ok, person} =
        People.create_person(%{full_name: "Person", phone: "123", role: "Person role"})

      {:ok, other} = People.create_person(%{full_name: "Other", phone: "456", role: "Other role"})

      assert {:ok, merged} =
               People.update_person_resource(
                 person,
                 %{phone: nil, merged_person_ids: [999], merge_history: []},
                 [],
                 %{merge_with_person_id: other.id, merge_precedence: unquote(precedence)}
               )

      assert merged.phone == nil

      assert merged.role ==
               if(unquote(precedence) == "person", do: "Person role", else: "Other role")

      assert merged.merged_person_ids == [
               if(unquote(precedence) == "person", do: other.id, else: person.id)
             ]

      assert length(merged.merge_history) == 1
    end
  end

  for {platform, identifier, duplicate} <- [
        {"email", "identity@example.com", " IDENTITY@EXAMPLE.COM "},
        {"telegram", "ExactID", "ExactID"}
      ] do
    test "#{platform} duplicate add and edit errors belong to the identifier across people" do
      {:ok, first} = People.create_person(%{full_name: "First"})
      {:ok, other} = People.create_person(%{full_name: "Other"})
      attrs = %{platform: unquote(platform), channel_identifier: unquote(identifier)}
      {:ok, original} = People.add_channel(Map.put(attrs, :person_id, first.id))

      for person <- [first, other] do
        assert {:error, error} =
                 People.add_channel(
                   Map.merge(attrs, %{
                     person_id: person.id,
                     channel_identifier: unquote(duplicate)
                   })
                 )

        assert errors_on(error).channel_identifier == [@duplicate]

        {:ok, editable} =
          People.add_channel(%{
            person_id: person.id,
            platform: unquote(platform),
            channel_identifier: "different-#{person.id}"
          })

        for changeset <- [&PersonChannel.changeset/2, &PersonChannel.update_changeset/2] do
          assert {:error, error} =
                   Repo.update(changeset.(editable, %{channel_identifier: unquote(duplicate)}),
                     mode: :savepoint
                   )

          assert errors_on(error).channel_identifier == [@duplicate]
        end

        assert People.get_channel(editable.id) == editable
      end

      assert People.get_channel(original.id) == original
    end
  end

  test "opaque IDs preserve case and whitespace, and the platform scopes uniqueness" do
    {:ok, person} = People.create_person(%{full_name: "Opaque"})

    for {platform, id} <- [
          {"telegram", "Exact"},
          {"telegram", "exact"},
          {"telegram", " Exact "},
          {"slack", "Exact"}
        ] do
      assert {:ok, channel} =
               People.add_channel(%{
                 person_id: person.id,
                 platform: platform,
                 channel_identifier: id
               })

      assert channel.channel_identifier == id
    end
  end

  test "person email auto-link conflicts roll back create and update without exposing owner" do
    {:ok, owner} = People.create_person(%{full_name: "Owner"})

    {:ok, _} =
      People.add_channel(%{
        person_id: owner.id,
        platform: "email",
        channel_identifier: "owned@example.com"
      })

    {:ok, editable} = People.create_person(%{full_name: "Editable"})

    assert {:error, error} =
             People.create_person(%{full_name: "Orphan", email: " OWNED@example.com "})

    assert errors_on(error).email == [@duplicate]
    refute Repo.exists?(from p in Person, where: p.full_name == "Orphan")

    assert {:error, error} =
             People.update_person(editable, %{full_name: "Changed", email: "owned@example.com"})

    assert errors_on(error).email == [@duplicate]
    assert People.get_person!(editable.id) == editable
  end

  test "discovery rejects contradictory email or phone and channel owners atomically" do
    {:ok, first} =
      People.create_person(%{full_name: "First", email: "first@example.com", phone: "123"})

    {:ok, second} = People.create_person(%{full_name: "Second"})

    {:ok, _} =
      People.add_channel(%{
        person_id: second.id,
        platform: "telegram",
        channel_identifier: "owned"
      })

    for identity <- [%{email: first.email}, %{phone: first.phone}] do
      assert {:error, error} =
               People.find_or_create_from_channel(
                 :telegram,
                 Map.merge(identity, %{channel_id: "owned", display_name: "Changed"})
               )

      assert errors_on(error).channel_identifier == [@duplicate]
      assert People.get_person!(first.id) == first
      assert People.get_person!(second.id) == second
    end
  end

  test "invalid partial channels and backfill email conflicts leave no partial writes" do
    assert {:error, _} = People.find_or_create_from_channel(:telegram, %{display_name: "Orphan"})
    refute Repo.exists?(from p in Person, where: p.full_name == "Orphan")
    {:ok, owner} = People.create_person(%{full_name: "Owner"})

    {:ok, _} =
      People.add_channel(%{
        person_id: owner.id,
        platform: "email",
        channel_identifier: "owned@example.com"
      })

    {:ok, partial} = People.find_or_create_from_channel(:telegram, %{channel_id: "partial"})

    assert {:error, _} =
             People.find_or_create_from_channel(:telegram, %{
               channel_id: "partial",
               email: "owned@example.com",
               display_name: "Changed"
             })

    assert People.get_person!(partial.id).email == nil
    assert People.get_person!(partial.id).full_name == "partial"
    assert length(People.list_person_channels(partial.id)) == 1
  end
end
