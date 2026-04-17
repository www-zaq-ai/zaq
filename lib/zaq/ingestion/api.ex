defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event

  @impl true
  def handle_event(%Event{} = event, :invoke, _context), do: invoke(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  defp invoke(%Event{request: %{module: mod, function: fun, args: args}} = event)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    %{event | response: apply(mod, fun, args)}
  end

  defp invoke(%Event{} = event) do
    %{event | response: {:error, {:invalid_request, event.request}}}
  end
end
