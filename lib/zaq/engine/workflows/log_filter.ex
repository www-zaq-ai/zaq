defmodule Zaq.Engine.Workflows.LogFilter do
  @moduledoc """
  `:logger` primary filter that suppresses the framework-level error/warning logs
  emitted when a workflow **edge condition is unmet**.

  Edge routing prunes the losing branch of a fork by raising a
  `ConditionNotMet` exception (see `Steps.EdgeStep`). This is
  expected control flow — every fork prunes at least one branch on every run — but
  Jido (`cond_log_error`, `:error`) and Runic (`Runnable failed`, `:warning`) both
  log each prune, so a healthy run emits one scary-looking line per unmet edge.

  This filter drops **only** those lines, identified by the `ConditionNotMet`
  marker in the rendered message. Genuine action failures (any other exception or
  `{:error, _}`) and all non-error/warning logs pass through untouched, so real
  problems stay loud.

  Registered once as a primary filter at application startup via
  `install/0`. Only `:error` and `:warning` events are inspected; every other level
  short-circuits without rendering, so the hot logging path is unaffected.
  """

  @filter_id :zaq_workflow_condition_not_met
  @marker "ConditionNotMet"

  @doc """
  Installs the primary filter. Idempotent: a second call (e.g. an app restart in
  the same VM) is a no-op rather than an error.
  """
  @spec install() :: :ok
  @spec install((atom(), term() -> :ok | {:error, term()})) :: :ok
  def install(add_primary_filter \\ &:logger.add_primary_filter/2) do
    case add_primary_filter.(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      # Never let logging setup crash boot; a filter that fails to install just
      # means the (harmless) prune logs remain visible.
      {:error, _reason} -> :ok
    end
  end

  @doc """
  `:logger` filter callback. Returns `:stop` to drop a ConditionNotMet prune log,
  otherwise `:ignore` to leave the event for the next filter/handler.
  """
  @spec filter(:logger.log_event(), term()) :: :stop | :ignore
  def filter(%{level: level, msg: msg}, _extra) when level in [:error, :warning] do
    if condition_not_met?(msg), do: :stop, else: :ignore
  end

  def filter(_event, _extra), do: :ignore

  defp condition_not_met?({:string, chardata}), do: contains_marker?(chardata)

  defp condition_not_met?({:report, report}), do: report |> inspect() |> contains_marker?()

  defp condition_not_met?({format, args}) when is_list(format) and is_list(args) do
    format |> :io_lib.format(args) |> contains_marker?()
  rescue
    _ -> false
  end

  defp condition_not_met?(_msg), do: false

  # Rendering must never crash the logging pipeline; on any error, fail open (keep
  # the log) rather than dropping something we could not inspect.
  defp contains_marker?(chardata) do
    chardata |> IO.chardata_to_string() |> String.contains?(@marker)
  rescue
    _ -> false
  end
end
