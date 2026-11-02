defmodule Zaq.Repo.Migrations.RetireChunkTitleTemplate do
  use Ecto.Migration

  def up do
    # Historical seeds still run on fresh installations. Remove only the shipped
    # template; user-owned prompts remain available as ordinary custom templates.
    table = if prefix(), do: "#{prefix()}.prompt_templates", else: "prompt_templates"
    execute("DELETE FROM #{table} WHERE slug = 'chunk_title' AND body_customized = false")
  end

  def down, do: :ok
end
