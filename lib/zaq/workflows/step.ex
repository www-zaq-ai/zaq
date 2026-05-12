defmodule Zaq.Workflows.Step do
  @moduledoc """
  Behaviour for workflow condition modules.

  Condition modules implement this behaviour so they can be referenced by name
  in `Workflow.steps` JSON and resolved at runtime by `DagBuilder`.

  Actions use `Jido.Action` (`run/2`). Conditions use this behaviour (`call/1`).

  ## Implementing a condition

      defmodule Zaq.Workflows.Conditions.MyCondition do
        @behaviour Zaq.Workflows.Step

        @impl true
        def call(fact), do: Map.get(fact, :some_field) == true

        @impl true
        def name, do: "my_condition"
      end

  ## Stored in `Workflow.steps` as

      %{"name" => "check", "type" => "condition",
        "module" => "Zaq.Workflows.Conditions.MyCondition", "params" => {}, "index" => 1}
  """

  @doc "Evaluates the condition against the current DAG fact map. Returns a boolean."
  @callback call(fact :: map()) :: boolean()

  @doc "Human-readable name for the step catalog and UI."
  @callback name() :: String.t()

  @doc "Optional description shown in the workflow builder UI."
  @callback description() :: String.t()

  @optional_callbacks [description: 0]
end
