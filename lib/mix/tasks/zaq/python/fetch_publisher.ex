defmodule Mix.Tasks.Zaq.Python.Fetch.Publisher do
  @moduledoc """
  Publishes a complete crawler tree and restores the previous tree on normal rename errors.

  Staging and destination must be on the same filesystem. Setup runs with ZAQ stopped;
  this module does not coordinate concurrent fetches or recover from process crashes.
  """

  require Logger

  @spec replace(Path.t(), Path.t()) :: :ok
  def replace(staging, destination) do
    backup = "#{destination}.previous-#{System.unique_integer([:positive])}"
    previous? = previous_tree?(destination)

    if previous?, do: move_previous(destination, backup)
    publish(staging, destination, backup, previous?)
  end

  defp previous_tree?(destination) do
    case File.lstat(destination) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, reason} -> Mix.raise("Could not inspect #{destination}: #{inspect(reason)}")
    end
  end

  defp move_previous(destination, backup) do
    case File.rename(destination, backup) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Could not move previous crawler tree: #{inspect(reason)}")
    end
  end

  defp publish(staging, destination, backup, previous?) do
    case File.rename(staging, destination) do
      :ok ->
        remove_previous(backup, previous?)
        :ok

      {:error, reason} ->
        restore_or_raise(destination, backup, previous?, reason)
    end
  end

  defp remove_previous(backup, true) do
    case File.rm_rf(backup) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Published tree; could not clean #{path}: #{inspect(reason)}")
    end
  end

  defp remove_previous(_backup, false), do: :ok

  defp restore_or_raise(destination, backup, true, reason) do
    case File.rename(backup, destination) do
      :ok ->
        Mix.raise("Failed to publish crawler tree: #{inspect(reason)}")

      {:error, rollback_reason} ->
        Mix.raise(
          "Failed to publish crawler tree: #{inspect(reason)}; " <>
            "rollback failed: #{inspect(rollback_reason)}; previous tree remains at #{backup}"
        )
    end
  end

  defp restore_or_raise(_destination, _backup, false, reason) do
    Mix.raise("Failed to publish crawler tree: #{inspect(reason)}")
  end
end
