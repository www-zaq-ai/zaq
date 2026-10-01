defmodule Zaq.System.UpdateBadgeWorker do
  @moduledoc """
  Checks GitHub releases and toggles the BO update badge flag.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Zaq.System
  alias Zaq.System.ReleaseUpdate

  @badge_key "ui.update_badge_enabled"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    force? = truthy?(Map.get(args, "force"))

    if not force? and badge_enabled?() do
      :ok
    else
      check_and_persist_badge(Map.get(args, "current_version"))
    end
  end

  def perform(_), do: check_and_persist_badge(nil)

  defp check_and_persist_badge(nil), do: check_and_persist_badge(Application.spec(:zaq, :vsn))

  defp check_and_persist_badge(current_version) do
    case ReleaseUpdate.check_for_update(current_version) do
      :update_available ->
        persist_badge(true)

      :up_to_date ->
        persist_badge(false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp badge_enabled? do
    @badge_key
    |> System.get_config()
    |> truthy?()
  end

  defp persist_badge(enabled) do
    case System.set_config(@badge_key, to_string(enabled)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp truthy?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(_), do: false
end
