defmodule Zaq.Repo.Migrations.AddAgentSampling do
  use Ecto.Migration

  def up do
    alter table(:configured_agents) do
      add :temperature, :float, null: false, default: 0.0
      add :top_p, :float, null: false, default: 0.9
    end

    flush()
    agents = qualified("configured_agents")
    configs = qualified("system_configs")

    # Snapshot the effective legacy merge (JSON overrides global sampling) once.
    # Authentication is deliberately not read by this data migration.
    execute("""
    UPDATE #{agents}
    SET temperature = COALESCE((advanced_options->>'temperature')::double precision,
          (SELECT value::double precision FROM #{configs} WHERE key = 'llm.temperature'), 0.0),
        top_p = COALESCE((advanced_options->>'top_p')::double precision,
          (SELECT value::double precision FROM #{configs} WHERE key = 'llm.top_p'), 0.9),
        advanced_options = COALESCE(advanced_options, '{}'::jsonb) - 'temperature' - 'top_p'
    """)
  end

  def down do
    # Restore overrides before removing columns so downgrade retains effective sampling.
    execute("""
    UPDATE #{qualified("configured_agents")}
    SET advanced_options = COALESCE(advanced_options, '{}'::jsonb) ||
      jsonb_build_object('temperature', temperature, 'top_p', top_p)
    """)

    alter table(:configured_agents) do
      remove :temperature
      remove :top_p
    end
  end

  defp qualified(table), do: if(prefix(), do: "#{prefix()}.#{table}", else: table)
end
