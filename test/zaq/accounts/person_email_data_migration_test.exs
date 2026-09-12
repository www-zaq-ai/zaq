unless Code.ensure_loaded?(Zaq.Repo.Migrations.NormalizePersonEmails) do
  Code.require_file(
    "../../../priv/repo/migrations/20260910194115_normalize_person_emails.exs",
    __DIR__
  )
end

defmodule Zaq.Accounts.PersonEmailDataMigrationTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Engine.{Conversations, IncomingMessageRoutingRule}
  alias Zaq.Repo.Migrations.NormalizePersonEmails

  @version 20_260_910_194_115

  property "disjoint mixed-platform chains partition once, choose lowest IDs, and rerun idempotently" do
    check all(size <- integer(2..7), reversed <- boolean(), max_runs: 12) do
      Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")

      groups =
        for group <- 1..2 do
          for person <- 1..size, do: legacy_person(" chain-#{group}-#{person}@EXAMPLE.COM ")
        end

      isolated = legacy_person(nil)

      for group <- groups do
        edges = Enum.chunk_every(group, 2, 1, :discard)
        edges = if reversed, do: Enum.reverse(edges), else: edges

        for [left, right] <- edges do
          platform = if rem(left, 2) == 0, do: "email", else: "telegram"
          identifier = "edge-#{left}@example.com"

          for {id, value} <- [
                {left, identifier},
                {right,
                 if(platform == "email",
                   do: " " <> String.upcase(identifier) <> " ",
                   else: identifier
                 )}
              ] do
            Repo.insert!(%PersonChannel{
              person_id: id,
              platform: platform,
              channel_identifier: value
            })
          end
        end
      end

      run_migration()

      for {[survivor | losers], group} <- Enum.with_index(groups, 1) do
        assert People.get_person!(survivor).merged_person_ids == losers
        for id <- losers, do: assert(People.get_person!(id).id == survivor)

        for person <- 1..size do
          assert {:ok, %{id: ^survivor}} =
                   People.match_by_channel("email", "chain-#{group}-#{person}@example.com")
        end
      end

      assert People.get_person!(isolated).merged_person_ids == []
      before = Repo.all(from p in Person, order_by: p.id)
      channels = Repo.all(from c in PersonChannel, order_by: c.id)
      run_migration()
      assert Repo.all(from p in Person, order_by: p.id) == before
      assert Repo.all(from c in PersonChannel, order_by: c.id) == channels
      ids = List.flatten(groups) ++ [isolated]
      Repo.delete_all(from p in Person, where: p.id in ^ids)
    end
  end

  setup do
    # Transactional DDL is restored by this serial DataCase's sandbox rollback.
    # No other test connection can see the legacy schema or its duplicate rows.
    Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS channels_person_id_platform_channel_identifier_index ON channels (person_id, platform, channel_identifier)"
    )

    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    :ok
  end

  for transitive <- [false, true] do
    test "preserves distinct profile emails without email channels, transitive #{transitive}" do
      first = legacy_person(" A@example.com ", "Survivor")
      second = legacy_person("b@example.com", "Loser")

      for id <- [first, second] do
        Repo.insert!(%PersonChannel{
          person_id: id,
          platform: "telegram",
          channel_identifier: "123"
        })
      end

      {ids, existing, expected_emails, expected_channels} =
        if unquote(transitive) do
          third = legacy_person("c@example.com")
          fourth = legacy_person(" B@EXAMPLE.COM ")

          for id <- [second, third, fourth] do
            Repo.insert!(%PersonChannel{
              person_id: id,
              platform: "slack",
              channel_identifier: "hop"
            })
          end

          existing =
            Repo.insert!(%PersonChannel{
              person_id: fourth,
              platform: "email",
              channel_identifier: " C@EXAMPLE.COM ",
              weight: 7,
              metadata: %{"keep" => true},
              last_interaction_at: ~U[2020-01-01 00:00:00Z]
            })

          {[first, second, third, fourth], existing,
           ["a@example.com", "b@example.com", "c@example.com"], 5}
        else
          {[first, second], nil, ["a@example.com", "b@example.com"], 3}
        end

      assert :ok = migrate()
      survivor = People.get_person_with_channels!(first)
      assert survivor.email == "a@example.com"
      assert survivor.full_name == "Survivor"
      assert survivor.merged_person_ids == tl(ids)
      assert length(survivor.channels) == expected_channels
      emails = Enum.filter(survivor.channels, &(&1.platform == "email"))
      assert Enum.sort(Enum.map(emails, & &1.channel_identifier)) == expected_emails

      if existing do
        retained = People.get_channel(existing.id)
        assert retained.person_id == first
        assert retained.weight == existing.weight
        assert retained.metadata == existing.metadata
        assert retained.last_interaction_at == existing.last_interaction_at
      end

      for email <- emails do
        unless existing && email.id == existing.id, do: assert(email.last_interaction_at == nil)
        identifier = " " <> String.upcase(email.channel_identifier) <> " "
        assert {:ok, %{id: ^first}} = People.match_by_channel("email", identifier)

        assert {:ok, %{id: ^first}} =
                 People.find_or_create_from_channel("email", %{
                   channel_id: identifier,
                   email: identifier
                 })
      end

      assert Repo.aggregate(Person, :count) == 1
      assert length(People.list_person_channels(first)) == expected_channels
      assert People.get_person!(first).email == "a@example.com"
      run_migration()
      assert People.get_person_with_channels!(first) == survivor
    end
  end

  test "mixed transitive channels and cross-field email identity merge one complete component" do
    first = legacy_person(" BRIDGE@example.com ")
    second = legacy_person(nil)
    third = legacy_person(nil)
    fourth = legacy_person("other@example.com")
    unrelated = legacy_person(nil)

    for {person_id, platform, identifier} <- [
          {second, "email", "bridge@example.com"},
          {second, "telegram", "Exact"},
          {third, "telegram", "Exact"},
          {third, "email", " OTHER@example.com "},
          {unrelated, "telegram", "exact"}
        ] do
      Repo.insert!(%PersonChannel{
        person_id: person_id,
        platform: platform,
        channel_identifier: identifier
      })
    end

    assert :ok = migrate()
    assert People.get_person!(first).merged_person_ids == [second, third, fourth]
    assert People.get_person!(first).email == "bridge@example.com"
    assert People.get_person!(unrelated).id == unrelated

    assert Enum.sort(
             Enum.map(People.list_person_channels(first), &{&1.platform, &1.channel_identifier})
           ) ==
             [
               {"email", "bridge@example.com"},
               {"email", "other@example.com"},
               {"telegram", "Exact"}
             ]

    assert [[true]] =
             Repo.query!(
               "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_platform_channel_identifier_index'::regclass"
             ).rows
  end

  test "singleton channel-only identities deduplicate every platform without changing opaque IDs" do
    # Exact per-person duplicates require the historical constraint absent too.
    Repo.query!("DROP INDEX IF EXISTS channels_person_id_platform_channel_identifier_index")
    person = legacy_person(nil)

    winner_ids =
      for platform <- ["email", "telegram"] do
        identifier = if platform == "email", do: " SINGLE@example.com ", else: " Exact "

        first =
          Repo.insert!(%PersonChannel{
            person_id: person,
            platform: platform,
            channel_identifier: identifier,
            weight: 7,
            metadata: %{"nested" => %{"keep" => false}},
            last_interaction_at: ~U[2020-01-01 00:00:00Z]
          })

        Repo.insert!(%PersonChannel{
          person_id: person,
          platform: platform,
          channel_identifier: identifier,
          weight: 2,
          metadata: %{"nested" => %{"keep" => true, "fill" => "yes"}},
          last_interaction_at: ~U[2021-01-01 00:00:00Z]
        })

        first.id
      end

    assert :ok = migrate()
    assert People.get_person!(person).email == nil
    assert People.get_person!(person).merged_person_ids == []
    channels = People.list_person_channels(person)
    assert length(channels) == 2
    assert Enum.sort(Enum.map(channels, & &1.id)) == winner_ids

    for channel <- channels do
      assert channel.weight == 7
      assert channel.metadata == %{"nested" => %{"keep" => false, "fill" => "yes"}}
      assert channel.last_interaction_at == ~U[2021-01-01 00:00:00Z]

      assert channel.channel_identifier ==
               if(channel.platform == "email", do: "single@example.com", else: " Exact ")
    end
  end

  test "blank legacy channel identifiers fail explicitly without bridging people or recording migration" do
    for platform <- ["email", "telegram"] do
      person = legacy_person(nil)

      Repo.insert!(%PersonChannel{
        person_id: person,
        platform: platform,
        channel_identifier: " \t"
      })
    end

    assert_raise Ecto.MigrationError, ~r/blank channel identifier/, &migrate/0
    assert Repo.aggregate(Person, :count) == 2

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]
  end

  test "real migrator applies three-way collision, delegates relationships and recorded rerun is a no-op" do
    first = legacy_person(" MIGRATION@example.com ", "First")
    second = legacy_person("Migration@example.com", "Second")
    third = legacy_person("migration@example.com", "Third")

    winner =
      Repo.insert!(%PersonChannel{
        person_id: first,
        platform: "email",
        channel_identifier: " MIGRATION@example.com ",
        weight: 4
      })

    Repo.insert!(%PersonChannel{
      person_id: first,
      platform: "email",
      channel_identifier: "migration@example.com"
    })

    Repo.insert!(%PersonChannel{
      person_id: second,
      platform: "email",
      channel_identifier: "Migration@example.com"
    })

    Repo.insert!(%PersonChannel{
      person_id: third,
      platform: "email",
      channel_identifier: "migration@example.com"
    })

    {:ok, channel} =
      People.add_channel(%{person_id: second, platform: "slack", channel_identifier: "migration"})

    {:ok, conversation} =
      Conversations.create_conversation(%{person_id: third, channel_type: "slack"})

    assert :ok = migrate()
    survivor = People.get_person!(first)
    assert survivor.email == "migration@example.com"
    assert [email] = Enum.filter(People.list_person_channels(first), &(&1.platform == "email"))
    assert email.id == winner.id
    assert email.weight == 4
    assert email.channel_identifier == "migration@example.com"
    assert survivor.merged_person_ids == [second, third]

    assert Enum.map(survivor.merge_history, &{&1["id"], &1["label"]}) ==
             [{second, "Second"}, {third, "Third"}]

    refute Repo.get(Person, second)
    assert People.get_person(third).id == first
    assert People.get_channel(channel.id).person_id == first
    assert Repo.get!(conversation.__struct__, conversation.id).person_id == first
    assert :already_up = migrate()
    assert People.get_person!(first) == survivor
    run_migration()
    assert People.get_person!(first) == survivor
    assert_raise Ecto.MigrationError, ~r/restore/, &NormalizePersonEmails.down/0
  end

  test "unexpected legacy unique violation raises and rolls back cleanup and the index ledger" do
    earlier = legacy_person(" EARLIER@example.com ")
    person = legacy_person(nil)

    for identifier <- [" LEGACY-BEFORE@example.com ", "legacy-blocked@example.com"] do
      Repo.insert!(%PersonChannel{
        person_id: person,
        platform: "email",
        channel_identifier: identifier
      })
    end

    originals = Repo.all(from c in PersonChannel, order_by: c.id)

    # A database-side rewrite forces a real, undeclared old-index violation
    # during cleanup. The normal migrator must propagate it, not map or hide it.
    Repo.query!("""
    CREATE FUNCTION identity_legacy_collision() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN NEW.channel_identifier := 'legacy-blocked@example.com'; RETURN NEW; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER identity_legacy_collision BEFORE UPDATE ON channels
    FOR EACH ROW WHEN (OLD.channel_identifier = ' LEGACY-BEFORE@example.com ')
    EXECUTE FUNCTION identity_legacy_collision()
    """)

    error = assert_raise Ecto.ConstraintError, &migrate/0
    assert error.constraint == "channels_person_id_platform_channel_identifier_index"
    assert Repo.get!(Person, earlier).email == " EARLIER@example.com "
    assert Repo.all(from c in PersonChannel, order_by: c.id) == originals

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]

    assert Repo.query!(
             "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
           ).rows == [[true]]

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []
  end

  test "failed merge rolls back earlier groups and migration ledger" do
    singleton = legacy_person(" SINGLE@example.com ")
    merged = legacy_person(" EARLIER@example.com ")
    alias_id = legacy_person("retained-loser@example.com")

    for id <- [merged, alias_id] do
      Repo.insert!(%PersonChannel{
        person_id: id,
        platform: "telegram",
        channel_identifier: "rollback-emails"
      })
    end

    original_channels = Repo.all(from c in PersonChannel, order_by: c.id)
    first = legacy_person("INVALID@example.com")
    second = legacy_person("invalid@example.com")
    Repo.insert!(%IncomingMessageRoutingRule{person_id: second, routing_mode: :agent})
    assert_raise Ecto.MigrationError, ~r/normalization failed/, &migrate/0
    assert Repo.get!(Person, singleton).email == " SINGLE@example.com "
    assert Repo.get!(Person, merged).email == " EARLIER@example.com "
    assert Repo.get!(Person, alias_id).merged_person_ids == []
    assert Repo.get!(Person, first).email == "INVALID@example.com"
    assert Repo.get!(Person, second).merged_person_ids == []
    assert Repo.all(from c in PersonChannel, order_by: c.id) == original_channels

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]

    assert [[true]] =
             Repo.query!(
               "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
             ).rows

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []
  end

  property "migration and storage have the same Unicode canonical form and rerunning is idempotent" do
    check all(
            local <-
              list_of(member_of(["A", "Ä", "İ", "Σ", "ẞ", "é", "É"]),
                min_length: 1,
                max_length: 8
              ),
            padding <- member_of([" ", "\u00A0", "\u2003", "\r\n"]),
            max_runs: 15
          ) do
      email = padding <> Enum.join(local) <> "@EXAMPLE.COM" <> padding
      id = legacy_person(email)
      run_migration()

      expected =
        %Person{} |> Person.changeset(%{full_name: "Person", email: email}) |> get_field(:email)

      assert Repo.get!(Person, id).email == expected
      run_migration()
      assert Repo.get!(Person, id).email == expected
      Repo.delete!(Repo.get!(Person, id))
    end
  end

  test "normalizes singletons, does not merge blank emails, and keeps uniqueness" do
    ids = for email <- [nil, "", " \t\u2003", " SINGLE@Example.com "], do: legacy_person(email)
    run_migration()
    assert Enum.map(ids, &Repo.get!(Person, &1).email) == [nil, nil, nil, "single@example.com"]

    assert {:error, changeset} =
             People.create_person(%{full_name: "New", email: "Single@EXAMPLE.com"})

    assert errors_on(changeset).email == ["has already been taken"]
  end

  defp run_migration do
    # Remove only this version to exercise the data operation again, rather than
    # merely observing the migrator's already-applied short circuit.
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")
    assert :ok = migrate()
  end

  defp migrate do
    Ecto.Migrator.up(Repo, @version, NormalizePersonEmails,
      log: false,
      migration_lock: false,
      skip_table_creation: true
    )
  end

  defp legacy_person(email, name \\ "Person") do
    Repo.insert!(%Person{email: email, full_name: name}).id
  end
end
