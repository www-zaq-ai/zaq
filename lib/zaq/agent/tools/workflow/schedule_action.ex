defmodule Zaq.Agent.Tools.Workflow.ScheduleAction do
  @moduledoc """
  Workflow action that schedules another registered action for later execution.

  `scheduled_at` must be an absolute UTC ISO8601 datetime. Use
  `workflow.to_utc_datetime` upstream when a caller starts with a delay or a
  timezone-qualified datetime.
  """

  use Zaq.Engine.Workflows.Action,
    name: "schedule_action",
    description: "Create or update a pending scheduled action by schedule id.",
    schema: [
      schedule_id: [type: :string, required: true, doc: "Stable identifier for this schedule."],
      action_key: [
        type: :string,
        required: true,
        doc: "Tool registry key for the action to run when the schedule fires."
      ],
      params: [type: :map, required: true, doc: "Params map passed to the scheduled action."],
      scheduled_at: [
        type: :string,
        required: true,
        doc: "Absolute UTC ISO8601 datetime, e.g. 2026-07-15T12:00:00Z."
      ]
    ],
    output_schema: [
      schedule_id: [type: :string, required: true],
      job_id: [type: :integer, required: true],
      scheduled_at: [type: :string, required: true]
    ]

  alias Zaq.Engine.ActionSchedules
  alias Zaq.MapUtils

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, scheduled_at} <- parse_utc_scheduled_at(MapUtils.fetch(params, :scheduled_at)),
         {:ok, job} <-
           ActionSchedules.schedule_action(%{
             schedule_id: MapUtils.fetch(params, :schedule_id),
             action_key: MapUtils.fetch(params, :action_key),
             params: MapUtils.fetch(params, :params),
             scheduled_at: scheduled_at
           }) do
      {:ok,
       %{
         schedule_id: MapUtils.fetch(job.args, :schedule_id),
         job_id: job.id,
         scheduled_at: DateTime.to_iso8601(job.scheduled_at)
       }}
    end
  end

  defp parse_utc_scheduled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      {:ok, _datetime, _offset} -> {:error, "scheduled_at must be UTC"}
      {:error, _} -> {:error, "scheduled_at must be a valid UTC ISO8601 datetime"}
    end
  end

  defp parse_utc_scheduled_at(_), do: {:error, "scheduled_at must be a UTC ISO8601 string"}
end
