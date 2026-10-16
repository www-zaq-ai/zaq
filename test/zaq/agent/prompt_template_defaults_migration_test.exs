unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddPromptTemplateDefaults) do
  Code.require_file(
    "../../../priv/repo/migrations/20261016193000_add_prompt_template_defaults.exs",
    __DIR__
  )
end

defmodule Zaq.Agent.PromptTemplateDefaultsMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.AddPromptTemplateDefaults

  @version 20_261_016_193_000
  @prefix "prompt_defaults_migration_test"

  setup do
    Repo.query!("CREATE SCHEMA #{@prefix}")

    Repo.query!("""
    CREATE TABLE #{@prefix}.prompt_templates (
      id bigserial PRIMARY KEY, slug text UNIQUE, name text, body text NOT NULL,
      description text, active boolean DEFAULT true,
      inserted_at timestamp, updated_at timestamp
    )
    """)

    :ok
  end

  test "timestamp classification upgrades untouched built-ins and preserves all other bodies" do
    insert("image_to_text", "unexpected but untouched", "2026-01-01", "2026-01-01", false)
    insert("chunk_title", "user's title prompt", "2026-01-01", "2026-01-02")
    insert("custom", "custom original", "2026-01-01", "2026-01-01")

    assert :ok = migrate(:up)
    assert :already_up = migrate(:up)

    assert [[body, body, false, false]] = row("image_to_text")
    assert body =~ "Use only information directly visible in the image"
    assert body =~ "Do not estimate or calculate values"
    assert [["user's title prompt", default, true, true]] = row("chunk_title")
    assert default =~ "document indexing assistant"
    assert [["custom original", nil, true, true]] = row("custom")

    # Future releases use the explicit flag, not timestamps or text equality.
    Repo.query!("""
    UPDATE #{@prefix}.prompt_templates
    SET default_body = 'next default',
        body = CASE WHEN body_customized THEN body ELSE 'next default' END
    WHERE slug IN ('image_to_text', 'chunk_title')
    """)

    assert [["next default", "next default", false, false]] = row("image_to_text")
    assert [["user's title prompt", "next default", true, true]] = row("chunk_title")

    assert :ok = migrate(:down)

    assert [["next default"], ["user's title prompt"], ["custom original"]] =
             Repo.query!("SELECT body FROM #{@prefix}.prompt_templates ORDER BY id").rows
  end

  test "null timestamps are conservative and missing built-ins are not recreated" do
    insert("image_to_text", "keep this", nil, nil)
    assert :ok = migrate(:up)
    assert [["keep this", default, true, true]] = row("image_to_text")
    assert is_binary(default)
    assert [[1]] = Repo.query!("SELECT count(*) FROM #{@prefix}.prompt_templates").rows
  end

  test "fresh seed timestamps adopt independent defaults for both built-ins" do
    for slug <- ["image_to_text", "chunk_title"] do
      insert(slug, "historical seed", "2026-01-01", "2026-01-01")
    end

    assert :ok = migrate(:up)

    for slug <- ["image_to_text", "chunk_title"] do
      assert [[default, default, false, true]] = row(slug)
      refute default == "historical seed"
    end
  end

  defp insert(slug, body, created, updated, active \\ true) do
    Repo.query!(
      """
      INSERT INTO #{@prefix}.prompt_templates
        (slug, name, body, inserted_at, updated_at, active)
      VALUES ($1, $1, $2, $3::text::timestamp, $4::text::timestamp, $5)
      """,
      [slug, body, created, updated, active]
    )
  end

  defp row(slug) do
    Repo.query!(
      "SELECT body, default_body, body_customized, active FROM #{@prefix}.prompt_templates WHERE slug = $1",
      [slug]
    ).rows
  end

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      @version,
      AddPromptTemplateDefaults,
      [prefix: @prefix, log: false, migration_lock: false]
    ])
  end
end
