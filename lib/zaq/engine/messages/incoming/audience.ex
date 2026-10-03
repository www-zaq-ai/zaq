defmodule Zaq.Engine.Messages.Incoming.Audience do
  @moduledoc """
  Message-local participant evidence normalized by the receiving channel.

  Identifiers are already canonical in their identity namespace. This value is
  data, not authentication: only trusted Channels events may assert an audience.
   The Engine resolves People without inspecting transport headers.
  """

  @enforce_keys [:platform, :sender, :recipients]
  defstruct [:platform, :sender, :recipients, participants: []]

  @type t :: %__MODULE__{
          platform: String.t(),
          sender: String.t(),
          recipients: [String.t()],
          participants: [map()]
        }

  @doc "Validates the normalized evidence; malformed evidence is never an empty audience."
  def normalize(%__MODULE__{} = audience), do: normalize(Map.from_struct(audience))

  def normalize(%{platform: platform, sender: sender, recipients: recipients} = attrs)
      when is_list(recipients) and length(recipients) <= 100 do
    if identifier?(platform) and identifier?(sender) and Enum.all?(recipients, &identifier?/1) do
      %__MODULE__{
        platform: platform,
        sender: sender,
        recipients: Enum.uniq(recipients),
        participants:
          normalize_participants(Map.get(attrs, :participants, []), [sender | recipients])
      }
    end
  end

  def normalize(_), do: nil

  defp normalize_participants(participants, identifiers) when is_list(participants) do
    participants
    |> Enum.take(101)
    |> Enum.flat_map(fn
      %{identifier: id, role: role} = participant when role in [:sender, :to, :cc] ->
        if id in identifiers do
          [%{identifier: id, role: role, display_name: Map.get(participant, :display_name)}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp normalize_participants(_, _), do: []

  defp identifier?(value),
    do: is_binary(value) and byte_size(value) in 1..255 and String.trim(value) == value
end
