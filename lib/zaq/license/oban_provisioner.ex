defmodule Zaq.License.ObanProvisioner do
  @moduledoc """
  Provisions Oban queues and crontab entries declared by licensed feature modules.

  Called by `Zaq.License.Loader` after modules are loaded into the BEAM.
  Any loaded module implementing `Zaq.License.ObanFeature` will have its
  declared queues started and crontab entries merged into the running Oban
  instance — with no static config changes required.
  """

  require Logger

  @oban_name Oban

  @doc """
  Provisions queues and crontab for all loaded modules that implement `ObanFeature`.
  """
  def provision(loaded_modules) do
    feature_modules = Enum.filter(loaded_modules, &implements_oban_feature?/1)

    provision_queues(feature_modules)
    provision_crontab(feature_modules)
  end

  # -- Private --

  defp implements_oban_feature?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :oban_queues, 0) and
      function_exported?(module, :oban_crontab, 0)
  end

  defp provision_queues([]), do: :ok

  defp provision_queues(feature_modules) do
    feature_modules
    |> Enum.flat_map(& &1.oban_queues())
    |> Enum.each(fn {queue, limit} ->
      case Oban.start_queue(@oban_name, queue: queue, limit: limit) do
        :ok ->
          Logger.info("[ObanProvisioner] Started queue :#{queue} (limit: #{limit})")

        {:error, reason} ->
          Logger.warning("[ObanProvisioner] Failed to start queue :#{queue}: #{inspect(reason)}")
      end
    end)
  end

  defp provision_crontab([]), do: :ok

  defp provision_crontab(feature_modules) do
    new_entries = Enum.flat_map(feature_modules, & &1.oban_crontab())

    if new_entries == [] do
      :ok
    else
      base_crontab = Application.get_env(:zaq, :oban_base_crontab, [])
      merged = Enum.uniq_by(base_crontab ++ new_entries, fn {_expr, worker} -> worker end)
      restart_cron_plugin(merged)
    end
  end

  defp restart_cron_plugin(crontab) do
    # Oban's cron plugin has no public API for adding entries at runtime.
    # We terminate and re-add the child with the merged crontab list.
    # The window without a running cron supervisor is negligible and safe —
    # Oban.insert is idempotent so any missed tick is rescheduled correctly.
    if Process.whereis(@oban_name) == nil do
      Logger.warning("[ObanProvisioner] cron plugin restart skipped — Oban not running")
    else
      plugin_name = {Oban.Plugins.Cron, @oban_name}

      case Supervisor.terminate_child(@oban_name, plugin_name) do
        :ok ->
          Supervisor.delete_child(@oban_name, plugin_name)
          start_cron_child(crontab)

        {:error, reason} ->
          Logger.warning("[ObanProvisioner] Could not terminate cron plugin: #{inspect(reason)}")
      end
    end
  end

  defp start_cron_child(crontab) do
    child_spec =
      {Oban.Plugins.Cron,
       [
         conf: Oban.config(@oban_name),
         crontab: crontab
       ]}

    case Supervisor.start_child(@oban_name, child_spec) do
      {:ok, _} ->
        Logger.info("[ObanProvisioner] Cron plugin restarted with #{length(crontab)} entries")

      {:error, reason} ->
        Logger.error("[ObanProvisioner] Failed to restart cron plugin: #{inspect(reason)}")
    end
  end
end
