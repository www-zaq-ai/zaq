# Run only with `MIX_ENV=test MIX_TEST_PARTITION=_person_alias_replay mix run --no-start ...`.
# Owns a disposable database and exercises the normal Repo-only migration runner.
unless Mix.env() == :test and System.get_env("MIX_TEST_PARTITION") == "_person_alias_replay" do
  raise "This replay requires its isolated test partition"
end

alias Zaq.Accounts.{People, Person, PersonChannel}
alias Zaq.Engine.IncomingMessageRoutingRule
alias Zaq.Repo

unless String.ends_with?(Repo.config()[:database], "_person_alias_replay") do
  raise "Refusing to replay against a non-disposable database"
end

Mix.Task.run("ecto.create")
Logger.configure(level: :warning)

try do
  {:ok, _, _} =
    Ecto.Migrator.with_repo(Repo, fn repo ->
      path = Application.app_dir(:zaq, "priv/repo/migrations")
      Ecto.Migrator.run(repo, path, :up, to: 20_260_910_153_017, log: false)

      people =
        for {email, name} <- [
              {" REPLAY@example.com ", "First"},
              {"Replay@example.com", "Second"},
              {"replay@example.com", "Third"}
            ] do
          Repo.insert!(%Person{full_name: name, email: email})
        end

      [first, second, third] = people

      bridge = Repo.insert!(%Person{full_name: "Channel bridge", email: " RETAINED@example.com "})

      for {id, platform, identifier} <- [
            {third.id, "telegram", "ReplayExact"},
            {bridge.id, "telegram", "ReplayExact"},
            {bridge.id, "email", "REPLAY@example.com"}
          ] do
        Repo.insert!(%PersonChannel{
          person_id: id,
          platform: platform,
          channel_identifier: identifier
        })
      end

      invalid_first = Repo.insert!(%Person{full_name: "Invalid", email: "INVALID@example.com"})
      invalid_second = Repo.insert!(%Person{full_name: "Invalid", email: "invalid@example.com"})

      invalid_rule =
        Repo.insert!(%IncomingMessageRoutingRule{
          person_id: invalid_second.id,
          routing_mode: :agent
        })

      original_channels = Repo.all(PersonChannel) |> Enum.sort_by(& &1.id)

      try do
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)
        raise "Expected invalid legacy routing to abort the data migration"
      rescue
        error in Ecto.MigrationError ->
          true = String.contains?(error.message, "normalization failed")
      end

      # A later failed collision must undo the earlier successful three-way merge
      # and leave the data version unapplied, while retaining the alias schema.
      true = Repo.get!(Person, first.id) == first
      true = Repo.get!(Person, second.id) == second
      true = Repo.get!(Person, third.id) == third
      true = Repo.get!(Person, invalid_first.id) == invalid_first
      true = Repo.get!(Person, bridge.id) == bridge
      true = Repo.all(PersonChannel) |> Enum.sort_by(& &1.id) == original_channels

      [[nil]] =
        Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows

      [[true]] =
        Repo.query!(
          "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
        ).rows

      [] =
        Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
          20_260_910_194_115
        ]).rows

      [[20_260_910_153_017]] =
        Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
          20_260_910_153_017
        ]).rows

      Repo.delete!(invalid_rule)

      collision_owner = Repo.insert!(%Person{full_name: "Legacy collision"})

      collision_channels =
        for identifier <- [" LEGACY-BEFORE@example.com ", "legacy-blocked@example.com"] do
          Repo.insert!(%PersonChannel{
            person_id: collision_owner.id,
            platform: "email",
            channel_identifier: identifier
          })
        end

      Repo.query!("""
      CREATE FUNCTION identity_legacy_collision() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN NEW.channel_identifier := 'legacy-blocked@example.com'; RETURN NEW; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER identity_legacy_collision BEFORE UPDATE ON channels
      FOR EACH ROW WHEN (OLD.channel_identifier = ' LEGACY-BEFORE@example.com ')
      EXECUTE FUNCTION identity_legacy_collision()
      """)

      try do
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)
        raise "Expected the undeclared legacy unique violation to abort cleanup"
      rescue
        error in Ecto.ConstraintError ->
          "channels_person_id_platform_channel_identifier_index" = error.constraint
      end

      for original <- people ++ [bridge, invalid_first, invalid_second, collision_owner] do
        true = Repo.get!(Person, original.id) == original
      end

      true =
        Repo.all(PersonChannel) |> Enum.sort_by(& &1.id) ==
          original_channels ++ collision_channels

      [[nil]] =
        Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows

      [[true]] =
        Repo.query!(
          "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
        ).rows

      [] =
        Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
          20_260_910_194_115
        ]).rows

      Repo.query!("DROP TRIGGER identity_legacy_collision ON channels")
      Repo.query!("DROP FUNCTION identity_legacy_collision()")
      Repo.delete!(collision_owner)

      # Force DDL failure after all cleanup completed, proving even the earlier
      # old-index drop and successful merges roll back with the ledger.
      Repo.query!("CREATE TABLE channels_platform_channel_identifier_index (id bigint)")

      try do
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)
        raise "Expected the conflicting relation name to abort index creation"
      rescue
        error in Postgrex.Error -> :duplicate_table = error.postgres.code
      end

      true = Repo.get!(Person, first.id) == first
      true = Repo.get!(Person, bridge.id) == bridge
      true = Repo.all(PersonChannel) |> Enum.sort_by(& &1.id) == original_channels

      [[true]] =
        Repo.query!(
          "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
        ).rows

      [] =
        Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
          20_260_910_194_115
        ]).rows

      Repo.query!("DROP TABLE channels_platform_channel_identifier_index")
      Ecto.Migrator.run(repo, path, :up, all: true, log: false)
      survivor = People.get_person!(first.id)
      true = survivor.email == "replay@example.com"
      true = survivor.merged_person_ids == [second.id, third.id, bridge.id]
      nil = Repo.get(Person, second.id)
      true = People.get_person(third.id).id == first.id
      true = People.get_person(bridge.id).id == first.id

      for email <- ["replay@example.com", "retained@example.com"] do
        {:ok, found} = People.match_by_channel("email", email)
        true = found.id == first.id

        {:ok, discovered} =
          People.find_or_create_from_channel("email", %{channel_id: email, email: email})

        true = discovered.id == first.id
      end

      channels = People.list_person_channels(first.id)
      3 = length(channels)
      retained = Enum.find(channels, &(&1.channel_identifier == "retained@example.com"))
      nil = retained.last_interaction_at
      2 = Repo.aggregate(Person, :count)
      true = People.get_person!(first.id).email == "replay@example.com"

      [[true]] =
        Repo.query!(
          "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_platform_channel_identifier_index'::regclass"
        ).rows

      [[nil]] =
        Repo.query!("SELECT to_regclass('channels_person_id_platform_channel_identifier_index')").rows

      {:error, duplicate} =
        People.add_channel(%{
          person_id: invalid_first.id,
          platform: "telegram",
          channel_identifier: "ReplayExact"
        })

      {"This channel identifier is already assigned.", _} = duplicate.errors[:channel_identifier]
      [] = Ecto.Migrator.run(repo, path, :up, all: true, log: false)
      true = People.get_person!(first.id) == survivor
      false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :zaq end)

      IO.puts(
        "PASS: fresh schema + transitive graph + retained profile email discovery + failed merge/legacy constraint/data/channels/index/ledger rollback + global uniqueness + retry + rerun; Repo-only, ZAQ application not started"
      )
    end)
after
  Mix.Task.run("ecto.drop", ["--force"])
end
