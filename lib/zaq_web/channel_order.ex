defmodule ZaqWeb.ChannelOrder do
  @moduledoc "Pure parent-owned draft moves for ordered channel rows. Invalid moves are no-ops."

  @doc "Moves a row to another row's index or one step up/down, preserving every row."
  def move(channels, id, action) do
    source = Enum.find_index(channels, &(&1.id == id))
    target = target_index(channels, source, action)

    if is_integer(source) and is_integer(target) and target >= 0 and target < length(channels) do
      {channel, remaining} = List.pop_at(channels, source)
      List.insert_at(remaining, target, channel)
    else
      channels
    end
  end

  defp target_index(_channels, nil, _action), do: nil
  defp target_index(_channels, source, "up"), do: source - 1
  defp target_index(_channels, source, "down"), do: source + 1
  defp target_index(channels, _source, id), do: Enum.find_index(channels, &(&1.id == id))

  @doc "Accessible status message for a successfully moved display row."
  def announcement(channels, id) do
    position = Enum.find_index(channels, &(&1.id == id))
    channel = Enum.at(channels, position)

    "#{channel.platform}, #{channel.identifier}, moved to position #{position + 1} of #{length(channels)}."
  end
end
