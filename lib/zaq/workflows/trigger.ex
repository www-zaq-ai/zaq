defmodule Zaq.Workflows.Trigger do
  @moduledoc """
  Ecto schema for a workflow trigger configuration.

  A trigger defines how a workflow is started. Multiple triggers can be
  attached to a single workflow. Disabled triggers are ignored by the
  runtime without needing to be deleted.

  Types:
  - `manual`    — fired explicitly by a user via the BO UI or API
  - `webhook`   — fired by an authenticated HTTP POST to `/webhooks/workflows/:id`
  - `scheduler` — fired on a cron schedule defined in `config.cron`
  - `signal`    — fired when a matching Jido signal is emitted; topic in `config.topic`
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(manual webhook scheduler signal)

  @type t :: %__MODULE__{}

  schema "triggers" do
    belongs_to :workflow, Workflow
    field :type, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def types, do: @types

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:workflow_id, :type, :config, :enabled])
    |> validate_required([:workflow_id, :type])
    |> validate_inclusion(:type, @types)
    |> validate_trigger_config()
    |> foreign_key_constraint(:workflow_id)
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
