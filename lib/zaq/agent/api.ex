defmodule Zaq.Agent.Api do
  @moduledoc """
  Agent role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Agent.Pipeline
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  @impl true
  def handle_event(%Event{} = event, :run_pipeline, _context) do
    case event.request do
      %Incoming{} = incoming ->
        pipeline_opts = Keyword.get(event.opts, :pipeline_opts, [])
        outgoing = Pipeline.run(incoming, pipeline_opts)
        %{event | response: outgoing}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

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
