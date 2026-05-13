defmodule Zaq.Repo.Migrations.SplitWorkflowStepsIntoNodesAndEdges do
  use Ecto.Migration

  def up do
    alter table(:workflows) do
      add :nodes, :map
      add :edges, :map
    end

    execute """
    UPDATE workflows
    SET nodes = COALESCE(steps->'nodes', '[]'::jsonb),
        edges = COALESCE(steps->'edges', '[]'::jsonb)
    """

    alter table(:workflows) do
      modify :nodes, :map, null: false, default: "[]"
      modify :edges, :map, null: false, default: "[]"
      remove :steps
    end
  end

  def down do
    alter table(:workflows) do
      add :steps, :map, null: false, default: "{}"
    end

    execute """
    UPDATE workflows
    SET steps = jsonb_build_object('nodes', COALESCE(nodes, '[]'::jsonb), 'edges', COALESCE(edges, '[]'::jsonb))
    """

    alter table(:workflows) do
      remove :nodes
      remove :edges
    end
  end
end
