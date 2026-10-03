defmodule Zaq.Engine.Messages.ReplyTargets do
  @moduledoc "Explicit, message-local delivery targets supplied by Channels, independent of conversation identity."
  defstruct to: [], cc: []
  @type t :: %__MODULE__{to: [String.t()], cc: [String.t()]}

  @spec normalize(term()) :: t() | nil
  def normalize(%__MODULE__{} = targets), do: normalize(Map.from_struct(targets))

  def normalize(%{to: to, cc: cc})
      when is_list(to) and is_list(cc) and length(to) + length(cc) <= 100 do
    if Enum.all?(to ++ cc, &(is_binary(&1) and byte_size(&1) in 1..255)) do
      to = Enum.uniq(to)
      %__MODULE__{to: to, cc: Enum.uniq(cc) -- to}
    end
  end

  def normalize(_), do: nil
end
