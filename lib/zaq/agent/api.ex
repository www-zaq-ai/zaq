defmodule Zaq.Agent.Api do
  @moduledoc """
  Agent role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Agent.Executor
  alias Zaq.Agent.Pipeline
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, :run_pipeline, _context) do
    case event.request do
      %Incoming{} = incoming ->
        pipeline_opts = Keyword.get(event.opts, :pipeline_opts, [])
        pipeline_module = Keyword.get(event.opts, :pipeline_module, Pipeline)
        executor_module = Keyword.get(event.opts, :executor_module, Executor)

        outgoing =
          case selected_agent_id(event.assigns) do
            nil ->
              pipeline_module.run(incoming, pipeline_opts)

            selected_id ->
              executor_module.run(incoming,
                agent_id: selected_id,
                history: Keyword.get(pipeline_opts, :history, %{}),
                telemetry_dimensions: Keyword.get(pipeline_opts, :telemetry_dimensions, %{})
              )
          end

        %{event | response: outgoing}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  defp selected_agent_id(assigns) when is_map(assigns) do
    case Map.get(assigns, "agent_selection") do
      %{"agent_id" => id} when id not in [nil, ""] -> id
      %{agent_id: id} when id not in [nil, ""] -> id
      _ -> nil
    end
  end

  defp selected_agent_id(_), do: nil
end
