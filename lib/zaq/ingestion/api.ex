defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
