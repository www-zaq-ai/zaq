defmodule Zaq.Channels.Mattermost.EventParser do
  @moduledoc """
  Parses raw Mattermost WebSocket events into clean structs.
  """

  defmodule Post do
    @moduledoc """
    Represents a Mattermost post event with relevant fields extracted.
    """
    defstruct [
      :id,
      :message,
      :user_id,
      :channel_id,
      :root_id,
      :sender_name,
      :channel_type,
      :channel_name,
      :create_at
    ]
  end

  def parse("posted", %{"data" => data}) do
    with {:ok, post} <- Jason.decode(data["post"]) do
      {:ok,
       %Post{
         id: post["id"],
         message: post["message"],
         user_id: post["user_id"],
         channel_id: post["channel_id"],
         root_id: post["root_id"],
         sender_name: data["sender_name"],
         channel_type: data["channel_type"],
         channel_name: data["channel_name"],
         create_at: post["create_at"]
       }}
    end
  end

  def parse(event_type, _raw) do
    {:unknown, event_type}
  end
end
