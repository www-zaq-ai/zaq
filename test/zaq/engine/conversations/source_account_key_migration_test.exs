unless Code.ensure_loaded?(Zaq.Repo.Migrations.WidenMessageSourceAccountKey) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261003000000_widen_message_source_account_key.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Conversations.SourceAccountKeyMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Conversations.Message
  alias Zaq.Repo.Migrations.WidenMessageSourceAccountKey

  @version 20_261_003_000_000
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "widens encoded source identities without changing existing bytes or uniqueness" do
    Repo.delete_all(Message)

    ordinary_key = Jason.encode!(["telegram", 12, "ordinary-room"])
    ordinary = insert_message!(ordinary_key, "ordinary")

    assert :ok = Ecto.Migrator.down(Repo, @version, WidenMessageSourceAccountKey, @opts)
    assert column_type() == {"character varying", 255}
    assert stored_key(ordinary.id) == ordinary_key

    assert :ok = Ecto.Migrator.up(Repo, @version, WidenMessageSourceAccountKey, @opts)
    assert column_type() == {"text", nil}
    assert stored_key(ordinary.id) == ordinary_key

    long_key = Jason.encode!(["telegram", 12, String.duplicate("a", 255)])
    assert byte_size(long_key) > 255
    long = insert_message!(long_key, "long")
    assert stored_key(long.id) == long_key

    assert {:error, changeset} =
             %Message{}
             |> Message.canonical_changeset(%{
               role: "external",
               content: "duplicate",
               source_provider: "telegram",
               source_account_key: long_key,
               external_message_id: "long"
             })
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).external_message_id

    assert_raise Postgrex.Error, ~r/Cannot narrow messages.source_account_key/, fn ->
      Ecto.Migrator.down(Repo, @version, WidenMessageSourceAccountKey, @opts)
    end

    assert stored_key(long.id) == long_key
  end

  defp insert_message!(key, external_id) do
    %Message{}
    |> Message.canonical_changeset(%{
      role: "external",
      content: external_id,
      source_provider: "telegram",
      source_account_key: key,
      external_message_id: external_id
    })
    |> Repo.insert!()
  end

  defp stored_key(id) do
    [[key]] =
      Repo.query!("SELECT source_account_key FROM messages WHERE id::text = $1", [id]).rows

    key
  end

  defp column_type do
    [[data_type, max_length]] =
      Repo.query!("""
      SELECT data_type, character_maximum_length
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'messages'
        AND column_name = 'source_account_key'
      """).rows

    {data_type, max_length}
  end
end
