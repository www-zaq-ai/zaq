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

    # Keep normalization self-contained so historical migrations do not depend on
    # runtime code. The temporary function is removed before this migration ends.
    execute("""
    CREATE OR REPLACE FUNCTION pg_temp.zaq_agent_sampling(raw text, minimum double precision,
      maximum double precision, fallback double precision, exclusive_minimum boolean)
    RETURNS double precision LANGUAGE plpgsql AS $$
    DECLARE parsed double precision;
    BEGIN
      parsed := raw::double precision;
      IF parsed <= maximum AND
        (CASE WHEN exclusive_minimum THEN parsed > minimum ELSE parsed >= minimum END) THEN
        RETURN parsed;
      END IF;
      RETURN fallback;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RETURN fallback;
    END;
    $$
    """)

    # Snapshot the effective legacy merge (JSON overrides global sampling) once.
    # Authentication is deliberately not read by this data migration.
    execute("""
    UPDATE #{agents}
    SET temperature = pg_temp.zaq_agent_sampling(
          CASE WHEN advanced_options ? 'temperature' THEN advanced_options->>'temperature'
            ELSE (SELECT value FROM #{configs} WHERE key = 'llm.temperature') END,
          0.0, 2.0, 0.0, false),
        top_p = pg_temp.zaq_agent_sampling(
          CASE WHEN advanced_options ? 'top_p' THEN advanced_options->>'top_p'
            ELSE (SELECT value FROM #{configs} WHERE key = 'llm.top_p') END,
          0.0, 1.0, 0.9, true),
        advanced_options = COALESCE(advanced_options, '{}'::jsonb) - 'temperature' - 'top_p'
    """)

    execute(
      "DROP FUNCTION pg_temp.zaq_agent_sampling(text, double precision, double precision, double precision, boolean)"
    )
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
