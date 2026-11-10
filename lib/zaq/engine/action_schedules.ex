defmodule Zaq.Engine.ActionSchedules do
  @moduledoc """
  Engine-owned scheduler for one-off action execution backed by Oban.

  Schedules are identified by caller-provided `schedule_id` values. Inserting a
  schedule with an existing pending `schedule_id` replaces the pending job's
  target action, params, and `scheduled_at` timestamp.
  """

  import Ecto.Query

  alias Oban.Job
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.ActionSchedules.Worker
  alias Zaq.Repo

  @pending_state_names ["scheduled"]
  @unique_pending_states [:scheduled]
  @queue :scheduled_actions

  @type attrs :: %{
          required(:schedule_id) => String.t(),
          required(:action_key) => String.t(),
          required(:params) => map(),
          required(:scheduled_at) => DateTime.t()
        }

  @doc """
  Creates or updates a pending scheduled action.

  The target action is resolved through `Zaq.Agent.Tools.Registry` and its input
  params are validated before the Oban job is inserted or replaced.
  """
  @spec schedule_action(attrs(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def schedule_action(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, schedule_id} <- fetch_non_empty_string(attrs, :schedule_id),
         {:ok, action_key} <- fetch_non_empty_string(attrs, :action_key),
         {:ok, params} <- fetch_params(attrs),
         {:ok, scheduled_at} <- fetch_utc_future_datetime(attrs),
         {:ok, module} <- resolve_action(action_key),
         {:ok, validated_params} <- validate_action_params(module, params) do
      insert_fun = Keyword.get(opts, :insert_fun, &Oban.insert/1)

      %{
        schedule_id: schedule_id,
        action_key: action_key,
        params: validated_params
      }
      |> Worker.new(
        queue: @queue,
        scheduled_at: scheduled_at,
        unique: [keys: [:schedule_id], states: @unique_pending_states, period: :infinity],
        replace: [scheduled: [:args, :scheduled_at, :worker, :queue]]
      )
      |> insert_fun.()
    end
  end

  @doc "Returns the pending Oban job for a schedule id, if one exists."
  @spec get_pending_schedule(String.t()) :: Job.t() | nil
  def get_pending_schedule(schedule_id) when is_binary(schedule_id) do
    pending_query()
    |> where([j], fragment("?->>'schedule_id'", j.args) == ^schedule_id)
    |> order_by([j], desc: j.inserted_at, desc: j.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Lists pending schedule jobs, optionally restricted to a list of ids."
  @spec list_pending_schedules([String.t()] | nil) :: [Job.t()]
  def list_pending_schedules(schedule_ids \\ nil)

  def list_pending_schedules(nil) do
    pending_query()
    |> order_by([j], asc: j.scheduled_at, asc: j.id)
    |> Repo.all()
  end

  def list_pending_schedules([]), do: []

  def list_pending_schedules(schedule_ids) when is_list(schedule_ids) do
    pending_query()
    |> where(
      [j],
      fragment("?->>'schedule_id' = ANY(?)", j.args, type(^schedule_ids, {:array, :string}))
    )
    |> order_by([j], asc: j.scheduled_at, asc: j.id)
    |> Repo.all()
  end

  @doc "Resolves an allowlisted action key to its module."
  @spec resolve_action(String.t()) :: {:ok, module()} | {:error, term()}
  def resolve_action(action_key) when is_binary(action_key) do
    case Enum.find(Registry.tools(), &(&1.key == action_key)) do
      %{module: module} -> {:ok, module}
      nil -> {:error, {:unknown_action, action_key}}
    end
  end

  def resolve_action(action_key), do: {:error, {:unknown_action, action_key}}

  @doc """
  Normalizes and validates params against an action's declared input schema.

  Delegates to `Zaq.Agent.Tools.ActionContract.validate/2`: it never executes
  the action, so scheduling has no side effects.
  """
  @spec validate_action_params(module(), map()) :: {:ok, map()} | {:error, term()}
  def validate_action_params(module, params) when is_map(params),
    do: ActionContract.validate(module, params)

  defp pending_query do
    from(j in Job,
      where: j.worker == ^inspect(Worker),
      where: j.queue == ^to_string(@queue),
      where: j.state in ^@pending_state_names
    )
  end

  defp fetch_non_empty_string(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_field, key, :blank}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid_field, key, :required_string}}
    end
  end

  defp fetch_params(attrs) do
    case Map.get(attrs, :params) || Map.get(attrs, "params") do
      params when is_map(params) -> {:ok, params}
      _ -> {:error, {:invalid_field, :params, :required_map}}
    end
  end

  defp fetch_utc_future_datetime(attrs) do
    case Map.get(attrs, :scheduled_at) || Map.get(attrs, "scheduled_at") do
      %DateTime{} = datetime -> validate_utc_future_datetime(datetime)
      _ -> {:error, {:invalid_field, :scheduled_at, :required_utc_datetime}}
    end
  end

  defp validate_utc_future_datetime(%DateTime{} = datetime) do
    cond do
      datetime.time_zone != "Etc/UTC" or datetime.utc_offset != 0 or datetime.std_offset != 0 ->
        {:error, {:invalid_field, :scheduled_at, :must_be_utc}}

      DateTime.compare(datetime, DateTime.utc_now()) != :gt ->
        {:error, {:invalid_field, :scheduled_at, :must_be_future}}

      true ->
        {:ok, datetime}
    end
  end
end
