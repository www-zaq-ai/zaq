defmodule Zaq.Engine.Api do
  @moduledoc """
  Engine role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, :persist_from_incoming, _context) do
    case event.request do
      %{incoming: %Incoming{} = incoming, metadata: metadata} when is_map(metadata) ->
        conversations_module = Keyword.get(event.opts, :conversations_module, Conversations)
        %{event | response: conversations_module.persist_from_incoming(incoming, metadata)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
