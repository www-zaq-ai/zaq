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
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "triggers" do
    field :event_name, :string
    field :enabled, :boolean, default: true

    many_to_many :workflows, Workflow,
      join_through: "trigger_workflows",
      join_keys: [trigger_id: :id, workflow_id: :id]

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:event_name, :enabled])
    |> validate_required([:event_name])
    |> validate_length(:event_name, min: 1)
    |> validate_format(:event_name, ~r/\S/, message: "can't be blank")
  end
end
