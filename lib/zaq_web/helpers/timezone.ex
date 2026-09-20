defmodule ZaqWeb.Helpers.Timezone do
  @moduledoc """
   Shared web timezone formatting. The default lookup uses Engine routing so
   BO and People pages do not require a local database connection.
  """

  alias Zaq.Config
  alias Zaq.Engine.Events

  def shift(nil), do: nil

  def shift(%DateTime{} = dt) do
    case system_timezone() do
      nil -> dt
      gmt_string -> shift_by_gmt_offset(dt, gmt_string)
    end
  end

  def shift(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> shift()
  end

  def offset_to_gmt_string(offset_str) do
    offset = String.to_integer(offset_str)
    hours = div(abs(offset), 60)
    mins = rem(abs(offset), 60)
    sign = if offset <= 0, do: "+", else: "-"

    "GMT#{sign}#{String.pad_leading(to_string(hours), 2, "0")}:#{String.pad_leading(to_string(mins), 2, "0")}"
  end

  defp shift_by_gmt_offset(%DateTime{} = dt, "GMT+" <> rest) do
    [h, m] = String.split(rest, ":")
    offset_sec = (String.to_integer(h) * 60 + String.to_integer(m)) * 60
    dt |> DateTime.to_naive() |> NaiveDateTime.add(offset_sec, :second)
  end

  defp shift_by_gmt_offset(%DateTime{} = dt, "GMT-" <> rest) do
    [h, m] = String.split(rest, ":")
    offset_sec = -(String.to_integer(h) * 60 + String.to_integer(m)) * 60
    dt |> DateTime.to_naive() |> NaiveDateTime.add(offset_sec, :second)
  end

  defp system_timezone do
    case Process.get(:zaq_system_timezone, :not_loaded) do
      :not_loaded -> load_system_timezone()
      timezone -> timezone
    end
  end

  defp load_system_timezone do
    fun = Config.get(:zaq, :system_timezone_fun, &engine_timezone/0, [])
    tz = fun.()
    Process.put(:zaq_system_timezone, tz)
    tz
  end

  defp engine_timezone do
    case Events.build_and_dispatch_invoke_event(%{}, :system_config_get_system_timezone).response do
      timezone when is_binary(timezone) -> timezone
      _ -> nil
    end
  end
end
