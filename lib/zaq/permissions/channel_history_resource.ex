defmodule Zaq.Permissions.ChannelHistoryResource do
  @moduledoc """
  Coordinates the history permission shared by a communication channel and its threads.

  The external channel and its connector identify the resource; a thread is never
  a separate permission resource. Callers must use trusted connector identity.
  """

  @type resource :: {String.t(), String.t()}

  @doc "Returns a collision-safe resource coordinate for a configured channel."
  @spec for(String.t(), pos_integer(), String.t()) :: resource()
  def for(provider, config_id, channel_id)
      when is_binary(provider) and provider != "" and is_integer(config_id) and config_id > 0 and
             is_binary(channel_id) and channel_id != "" do
    {"channel_history", Jason.encode!([provider, config_id, channel_id])}
  end

  @doc "Checks a direct Person grant on the channel shared by its parent and threads."
  @spec can_read?(Zaq.Accounts.Person.t() | nil, resource()) :: boolean()
  def can_read?(person, {"channel_history", _id} = resource),
    do: Zaq.Permissions.can?(person, :read, resource, direct_person_only: true)
end
