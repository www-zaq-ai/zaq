defmodule Zaq.InternalBoundaries do
  @moduledoc """
  Behaviour implemented by role-level API modules that receive routed events.

  Also exposes shared helpers used by those boundary modules.
  """

  alias Zaq.Event

  @doc """
  Handles an event routed to this role.

  ## Parameters
    - event: The event to handle
    - action: The action to perform (e.g., :invoke, :run_pipeline)
    - params: Reserved for future use. Currently always nil.
  """
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

  @doc """
  Shared default role boundary handler.

  Handles `:invoke` through `invoke_request/1` and returns
  `{:error, {:unsupported_action, action}}` for all other actions.
  """
  @spec default_handle_event(Event.t(), atom()) :: Event.t()
  def default_handle_event(%Event{} = event, :invoke), do: invoke_request(event)

  def default_handle_event(%Event{} = event, action) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
