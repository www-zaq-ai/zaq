defmodule Zaq.InternalBoundaries do
  @moduledoc """
  Behaviour implemented by role-level API modules that receive routed events.

  Also exposes shared helpers used by those boundary modules.
  """

  alias Zaq.Event

  @callback handle_event(Event.t(), atom(), map() | nil) :: Event.t()

  @doc """
  Executes `%{module, function, args}` stored in `event.request` and stores
  the result in `event.response`.

  Invalid request shapes produce `{:error, {:invalid_request, request}}`.
  """
  @spec invoke_request(Event.t()) :: Event.t()
  def invoke_request(%Event{request: %{module: mod, function: fun, args: args}} = event)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    %{event | response: apply(mod, fun, args)}
  end

  def invoke_request(%Event{} = event) do
    %{event | response: {:error, {:invalid_request, event.request}}}
  end
end
