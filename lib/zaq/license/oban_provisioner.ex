defmodule Zaq.License.ObanProvisioner do
  @moduledoc """
  Provisions Oban queues and crontab entries declared by licensed feature modules.

  Called by `Zaq.License.Loader` after modules are loaded into the BEAM.
  Any loaded module implementing `Zaq.License.ObanFeature` will have its
  declared queues started and crontab entries injected into the running
  `Zaq.Oban.DynamicCron` plugin — with no Oban supervisor restart required.
  """

  alias Zaq.Oban.DynamicCron

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
      function_exported?(module, :feature_key, 0) and
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
    Enum.each(feature_modules, fn module ->
      key = module.feature_key()
      entries = module.oban_crontab()

      if entries != [] do
        DynamicCron.add_schedules(key, entries)
      end
    end)
  end
end
