defmodule Zaq.Oban.DynamicCron do
  @moduledoc """
  Custom Oban plugin that replaces `Oban.Plugins.Cron` with runtime schedule injection support.

  Starts with a static base crontab from config (same syntax as `Oban.Plugins.Cron`) and
  accepts additional entries at runtime via `add_schedules/2`, keyed by feature atom for
  idempotency.

  Scheduling logic borrowed from `Oban.Plugins.Cron` (Apache 2.0).

  ## Usage in config

      plugins: [{Zaq.Oban.DynamicCron, crontab: [{"* * * * *", MyWorker}]}]

  ## Injecting from a licensed feature

      Zaq.Oban.DynamicCron.add_schedules(:my_feature, [{"0 * * * *", MyFeature.Worker}])

  The call is idempotent — subsequent calls with the same key are no-ops.
  """

  @behaviour Oban.Plugin

  use GenServer

  alias Oban.{Cron, Peer, Repo, Worker}
  alias Oban.Cron.Expression

  require Logger

  @oban_name Oban

  defstruct [
    :conf,
    :timer,
    crontab: [],
    timezone: "Etc/UTC",
    registered_keys: MapSet.new()
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Adds crontab entries for `feature_key`.

  Idempotent — if `feature_key` was already registered this call is a no-op.
  Deduplicates by worker module against the existing schedule.
  """
  @spec add_schedules(
          atom(),
          [{String.t(), module()} | {String.t(), module(), keyword()}]
        ) :: :ok
  def add_schedules(feature_key, entries) do
    name = Oban.Registry.via(@oban_name, {:plugin, __MODULE__})
    GenServer.call(name, {:add_schedules, feature_key, entries})
  end

  # ---------------------------------------------------------------------------
  # Oban.Plugin callbacks
  # ---------------------------------------------------------------------------

  @impl Oban.Plugin
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oban.Plugin
  def validate(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected a keyword list, got: #{inspect(opts)}"}

      Keyword.has_key?(opts, :crontab) and not is_list(opts[:crontab]) ->
        {:error, "expected :crontab to be a list"}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    conf = Keyword.fetch!(opts, :conf)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    raw_crontab = Keyword.get(opts, :crontab, [])

    state = %__MODULE__{
      conf: conf,
      timezone: timezone,
      crontab: parse_entries(raw_crontab)
    }

    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: conf, plugin: __MODULE__})

    {:ok, schedule_evaluate(state)}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    :ok
  end

  @impl GenServer
  def handle_info(:evaluate, %__MODULE__{} = state) do
    if Peer.leader?(state.conf) do
      insert_scheduled_jobs(state)

      {:noreply,
       state
       |> discard_reboots()
       |> schedule_evaluate()}
    else
      {:noreply, schedule_evaluate(state)}
    end
  end

  def handle_info(message, state) do
    Logger.warning("[DynamicCron] Unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:add_schedules, feature_key, entries}, _from, state) do
    if MapSet.member?(state.registered_keys, feature_key) do
      Logger.debug("[DynamicCron] Skipping already-registered feature: #{inspect(feature_key)}")
      {:reply, :ok, state}
    else
      new_entries = parse_entries(entries)

      merged =
        Enum.uniq_by(
          state.crontab ++ new_entries,
          fn {expr, _parsed, worker, opts} ->
            Oban.Plugins.Cron.entry_name({expr, worker, opts})
          end
        )

      new_state = %{
        state
        | crontab: merged,
          registered_keys: MapSet.put(state.registered_keys, feature_key)
      }

      Logger.info(
        "[DynamicCron] Registered #{length(new_entries)} schedule(s) for feature :#{feature_key}"
      )

      {:reply, :ok, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduling helpers (borrowed from Oban.Plugins.Cron)
  # ---------------------------------------------------------------------------

  defp schedule_evaluate(state) do
    timer = Process.send_after(self(), :evaluate, Cron.interval_to_next_minute())
    %{state | timer: timer}
  end

  defp discard_reboots(state) do
    crontab =
      Enum.reject(state.crontab, fn {_expr, parsed, _worker, _opts} -> parsed.reboot? end)

    %{state | crontab: crontab}
  end

  # ---------------------------------------------------------------------------
  # Insertion helpers (borrowed from Oban.Plugins.Cron)
  # ---------------------------------------------------------------------------

  defp insert_scheduled_jobs(state) do
    fun = fn ->
      {:ok, datetime} = DateTime.now(state.timezone)

      for {expr, parsed, worker, opts} <- state.crontab,
          Expression.now?(parsed, datetime) do
        Oban.insert!(state.conf.name, build_changeset(worker, opts, expr, state.timezone))
      end
    end

    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      case Repo.transaction(state.conf, fun) do
        {:ok, inserted_jobs} -> {:ok, Map.put(meta, :jobs, inserted_jobs)}
        error -> {:error, Map.put(meta, :error, error)}
      end
    end)
  end

  defp build_changeset(worker, opts, expr, timezone) do
    name = Oban.Plugins.Cron.entry_name({expr, worker, opts})
    {args, opts} = Keyword.pop(opts, :args, %{})

    meta = %{cron: true, cron_expr: expr, cron_name: name, cron_tz: timezone}

    opts =
      worker.__opts__()
      |> Worker.merge_opts(opts)
      |> Keyword.update(:meta, meta, &Map.merge(&1, meta))

    worker.new(args, opts)
  end

  # ---------------------------------------------------------------------------
  # Parsing helpers
  # ---------------------------------------------------------------------------

  defp parse_entries(entries) do
    Enum.map(entries, fn
      {expr, worker} -> {expr, Expression.parse!(expr), worker, []}
      {expr, worker, opts} -> {expr, Expression.parse!(expr), worker, opts}
    end)
  end
end
