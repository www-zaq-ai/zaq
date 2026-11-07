defmodule ZaqWeb.Live.BO.EngineDispatch do
  @moduledoc """
  Shared Back Office helper for dispatching Engine role events.
  """

  alias Phoenix.LiveView
  alias Zaq.{Event, NodeRouter}

  def dispatch(action, request \\ %{}, opts \\ []) when is_list(opts) do
    {actor, event_opts} = Keyword.pop(opts, :actor)

    request
    |> Event.new(:engine, actor: actor, opts: Keyword.put(event_opts, :action, action))
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  def dispatch_confidential(action, request \\ %{}, opts \\ []) when is_list(opts) do
    dispatch(action, request, Keyword.put(opts, :confidential, true))
  end

  def format_error(prefix, {:service_unavailable, :engine}),
    do: "#{prefix}: Engine service is unavailable."

  def format_error(prefix, reason),
    do: "#{prefix}: #{inspect(reason)}"

  def maybe_put_error_flash(socket, nil, _prefix), do: socket

  def maybe_put_error_flash(socket, {:service_unavailable, :engine}, _prefix) do
    LiveView.put_flash(socket, :error, "Engine service is unavailable.")
  end

  def maybe_put_error_flash(socket, reason, prefix) do
    LiveView.put_flash(socket, :error, "#{prefix}: #{inspect(reason)}")
  end
end
