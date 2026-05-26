defmodule Zaq.Engine.Workflows.Trigger do
  @moduledoc """
  Ecto schema for a workflow trigger configuration.

  Triggers are event-driven: each trigger record declares the `event_name` atom
  (stored as a string) that causes it to fire. When `NodeRouter.dispatch/1`
  broadcasts an event whose `name` matches a trigger's `event_name`, the
  `Engine.EventRegistry` delegates to `Engine.TriggerNode`, which creates and
  starts runs for every active workflow linked to that trigger via the
  `trigger_workflows` join table.

  A trigger can be disabled without deleting it — set `enabled: false`.

  ## Trigger types

  - `"event"` (default) — fires when a matching `event_name` is broadcast via NodeRouter.
  - `"cron"` — fires on the schedule defined by `cron_schedule` (standard 5-field cron
    expression, e.g. `"0 * * * *"` for hourly). The Oban worker
    `Zaq.Engine.Workflows.CronTriggerWorker` dispatches the trigger's `event_name` as a
    `%Zaq.Event{}`, so the existing `EventRegistry → TriggerNode` path handles execution
    identically for both types.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @valid_types ~w(event cron)

  # 5-field cron expression: each field is non-whitespace, separated by single spaces
  @cron_pattern ~r/^\S+\s+\S+\s+\S+\s+\S+\s+\S+$/

  schema "triggers" do
    field :event_name, :string
    field :enabled, :boolean, default: true
    field :trigger_type, :string, default: "event"
    field :cron_schedule, :string

    many_to_many :workflows, Workflow,
      join_through: "trigger_workflows",
      join_keys: [trigger_id: :id, workflow_id: :id]

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:event_name, :enabled, :trigger_type, :cron_schedule])
    |> normalize_event_name()
    |> validate_required([:event_name])
    |> validate_length(:event_name, min: 1)
    |> validate_format(:event_name, ~r/\S/, message: "can't be blank")
    |> validate_inclusion(:trigger_type, @valid_types)
    |> validate_cron_fields()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # EventRegistry keys are derived as "destination:name". All workflow triggers
  # target the :engine role, so event names must be stored with the "engine:"
  # prefix so that EventRegistry.fire_or_register can match them.
  # e.g. "order.placed"  →  "engine:order.placed"
  #      "engine:order.placed"  →  unchanged (idempotent)
  defp normalize_event_name(changeset) do
    case get_change(changeset, :event_name) do
      nil ->
        changeset

      name ->
        normalized =
          if String.contains?(name, ":") do
            name
          else
            "engine:#{name}"
          end

        put_change(changeset, :event_name, normalized)
    end
  end

  defp validate_cron_fields(changeset) do
    trigger_type = get_field(changeset, :trigger_type)
    cron_schedule = get_field(changeset, :cron_schedule)

    case trigger_type do
      "cron" ->
        changeset
        |> validate_required([:cron_schedule], message: "is required for cron triggers")
        |> validate_format(:cron_schedule, @cron_pattern,
          message: "must be a valid 5-field cron expression"
        )

      _event ->
        if cron_schedule in [nil, ""] do
          changeset
        else
          add_error(changeset, :cron_schedule, "must be blank for event triggers")
        end
    end
  end
end
