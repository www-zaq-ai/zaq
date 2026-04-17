defmodule Zaq.Channels.Api do
  @moduledoc """
  Channels role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Channels.Router
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{request: %Outgoing{} = outgoing} = event, :deliver_outgoing, _context) do
    router_module = Keyword.get(event.opts, :router_module, Router)
    %{event | response: router_module.deliver(outgoing)}
  end

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
