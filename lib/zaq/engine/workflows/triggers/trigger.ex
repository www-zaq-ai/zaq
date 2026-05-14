defmodule Zaq.Engine.Workflows.Trigger do
  @moduledoc """
  Ecto schema for a workflow trigger configuration.

  Triggers are standalone entities — created independently and then assigned to
  one or more workflows via the `trigger_workflows` join table. A trigger can
  also chain into other triggers via the `trigger_chains` table.

  Types:
  - `manual`    — fired explicitly via the BO UI or API; also available implicitly
                  on every workflow without a trigger record
  - `webhook`   — fired by an authenticated HTTP POST to `/webhooks/triggers/:id`
  - `scheduler` — fired on a cron schedule defined in `config.cron`
  - `signal`    — fired when a matching Jido signal is emitted; topic in `config.topic`

  Execution modes:
  - `parallel` (default) — all assigned workflows dispatched concurrently, capped
                           at `max_concurrency` (nil = unlimited). All run to
                           completion regardless of failures.
  - `serial`  — workflows run in `position` order. `on_failure` controls whether
                to stop on the first failure or continue through all workflows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Trigger.Chain
  alias Zaq.Engine.Workflows.Trigger.Workflow, as: TriggerWorkflow
  alias Zaq.Engine.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(manual webhook scheduler signal)

  @type t :: %__MODULE__{}

  schema "triggers" do
    field :type, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :execution_mode, Ecto.Enum, values: [:serial, :parallel], default: :parallel
    field :max_concurrency, :integer
    field :on_failure, Ecto.Enum, values: [:stop, :continue], default: :continue

    many_to_many :workflows, Workflow,
      join_through: TriggerWorkflow,
      join_keys: [trigger_id: :id, workflow_id: :id]

    many_to_many :downstream_triggers, __MODULE__,
      join_through: Chain,
      join_keys: [trigger_id: :id, downstream_trigger_id: :id]

    timestamps(type: :utc_datetime)
  end

  def types, do: @types

  @type_to_module %{
    "manual" => Zaq.Engine.Workflows.Trigger.Type.Manual,
    "webhook" => Zaq.Engine.Workflows.Trigger.Type.Webhook,
    "scheduler" => Zaq.Engine.Workflows.Trigger.Type.Scheduler,
    "signal" => Zaq.Engine.Workflows.Trigger.Type.Signal
  }

  @doc "Returns the trigger behaviour module for the given trigger's type."
  @spec module(t()) :: {:ok, module()} | {:error, :unknown_type}
  def module(%__MODULE__{type: type}) do
    case Map.fetch(@type_to_module, type) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_type}
    end
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :config, :enabled, :execution_mode, :max_concurrency, :on_failure])
    |> validate_required([:type])
    |> validate_inclusion(:type, @types)
    |> validate_number(:max_concurrency, greater_than: 0)
    |> validate_trigger_config()
  end

  defp validate_trigger_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    required_keys =
      case type do
        "scheduler" -> ["cron"]
        "signal" -> ["topic"]
        _ -> []
      end

    missing = Enum.reject(required_keys, &Map.has_key?(config, &1))

    Enum.reduce(missing, changeset, fn key, cs ->
      add_error(cs, :config, "missing required key '#{key}' for #{type} trigger")
    end)
  end
end
