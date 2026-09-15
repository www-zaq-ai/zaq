# Repo-only replay in a NEW isolated partition. Never resets or drops a database.
partition = System.get_env("MIX_TEST_PARTITION", "")

unless Mix.env() == :test and String.starts_with?(partition, "_people_history_replay_") do
  raise "Use a unique _people_history_replay_ test partition"
end

alias Zaq.Accounts.{People, Person, PersonSession}
alias Zaq.Engine.Conversations.{Conversation, Message, MessageRating}
alias Zaq.Engine.IncomingMessageRoutingRule
alias Zaq.Repo

database = Repo.config()[:database]

unless String.ends_with?(database, partition) and byte_size(database) <= 63 do
  raise "Use an isolated partition whose database name fits PostgreSQL's 63-byte limit"
end

Application.ensure_all_started(:postgrex)

unless Repo.__adapter__().storage_status(Repo.config()) == :down do
  raise "Replay requires a new database; existing partitions are never reused"
end

Mix.Task.run("ecto.create")
Logger.configure(level: :warning)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Repo, fn repo ->
    path = Application.app_dir(:zaq, "priv/repo/migrations")
    Ecto.Migrator.run(repo, path, :up, to: 20_260_910_170_000, log: false)

    [["person_id"]] =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'message_ratings' AND column_name = 'person_id'"
      ).rows

    first = Repo.insert!(%Person{full_name: "First", email: " REPLAY@example.test "})
    second = Repo.insert!(%Person{full_name: "Second", email: "replay@example.test"})

    conv =
      Repo.insert!(%Conversation{
        title: "Replay history",
        person_id: second.id,
        channel_type: "api"
      })

    first_message =
      Repo.insert!(%Message{conversation_id: conv.id, role: "assistant", content: "Conflict"})

    second_message =
      Repo.insert!(%Message{conversation_id: conv.id, role: "assistant", content: "Transfer"})

    retained =
      Repo.insert!(%MessageRating{message_id: first_message.id, person_id: first.id, rating: 5})

    discarded =
      Repo.insert!(%MessageRating{message_id: first_message.id, person_id: second.id, rating: 1})

    transferred =
      Repo.insert!(%MessageRating{message_id: second_message.id, person_id: second.id, rating: 4})

    now = DateTime.utc_now(:second)

    session =
      Repo.insert!(%PersonSession{
        person_id: first.id,
        token_digest: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.add(now, 3600)
      })

    bad_rule =
      Repo.insert!(%IncomingMessageRoutingRule{person_id: second.id, routing_mode: :agent})

    try do
      Ecto.Migrator.run(repo, path, :up, all: true, log: false)
      raise "Expected invalid legacy routing to roll normalization back"
    rescue
      error in Ecto.MigrationError ->
        true = String.contains?(error.message, "normalization failed")
    end

    true = Repo.get!(Person, second.id).id == second.id
    true = Repo.get!(MessageRating, discarded.id).person_id == second.id
    nil = Repo.get!(PersonSession, session.id).revoked_at
    Repo.delete!(bad_rule)
    Ecto.Migrator.run(repo, path, :up, all: true, log: false)
    true = People.get_person(second.id).id == first.id
    true = Repo.get!(Conversation, conv.id).person_id == first.id
    true = Repo.get!(MessageRating, retained.id).rating == 5
    nil = Repo.get(MessageRating, discarded.id)
    true = Repo.get!(MessageRating, transferred.id).person_id == first.id
    true = not is_nil(Repo.get!(PersonSession, session.id).revoked_at)
    [] = Ecto.Migrator.run(repo, path, :up, all: true, log: false)

    [[index_definition]] =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'conversations_person_activity_index'"
      ).rows

    true = String.contains?(index_definition, "person_id, updated_at, id")
    false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :zaq end)

    IO.puts(
      "PASS: fresh Repo-only replay; authentication and rating schema precede normalization; rollback, survivor-first rating reconciliation, ownership transfer and idempotent rerun. Isolated database retained: #{Repo.config()[:database]}"
    )
  end)
