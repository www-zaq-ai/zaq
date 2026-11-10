unless Code.ensure_loaded?(Zaq.Repo.Migrations.RetireChunkTitleTemplate) do
  Code.require_file(
    "../../../priv/repo/migrations/20261031130000_retire_chunk_title_template.exs",
    __DIR__
  )
end

defmodule Zaq.Agent.RetireChunkTitleTemplateMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.RetireChunkTitleTemplate

  test "retires only the unused shipped template and preserves user-owned prompts" do
    for customized <- [false, true] do
      prefix = "retire_chunk_title_#{customized}"
      Repo.query!("CREATE SCHEMA #{prefix}")
      Repo.query!("CREATE TABLE #{prefix}.prompt_templates (slug text, body_customized boolean)")

      Repo.query!(
        "INSERT INTO #{prefix}.prompt_templates VALUES ('chunk_title', $1), ('image_to_text', false)",
        [customized]
      )

      assert :ok =
               Ecto.Migrator.up(Repo, 20_261_031_130_000, RetireChunkTitleTemplate,
                 prefix: prefix,
                 log: false,
                 migration_lock: false
               )

      assert [["image_to_text"]] =
               Repo.query!(
                 "SELECT slug FROM #{prefix}.prompt_templates WHERE slug != 'chunk_title'"
               ).rows

      assert [[count]] =
               Repo.query!(
                 "SELECT count(*) FROM #{prefix}.prompt_templates WHERE slug = 'chunk_title'"
               ).rows

      assert count == if(customized, do: 1, else: 0)
    end
  end
end
