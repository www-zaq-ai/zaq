defmodule Zaq.Repo.Migrations.WidenMessageSourceAccountKey do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE messages ALTER COLUMN source_account_key TYPE text")
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1
        FROM messages
        WHERE char_length(source_account_key) > 255
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'Cannot narrow messages.source_account_key while encoded identities exceed 255 characters';
      END IF;
    END $$
    """)

    execute(
      "ALTER TABLE messages ALTER COLUMN source_account_key TYPE varchar(255) USING source_account_key::varchar(255)"
    )
  end
end
