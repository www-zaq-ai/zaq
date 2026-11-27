defmodule ZaqWeb.Live.BO.Communication.CapabilitySnapshot do
  @moduledoc """
  Presentation state for the current connector's routed capability result.

  Successful empty snapshots stay distinct from lookup failures. Authoritative
  save errors can supply normalized facts without replacing any form drafts.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Zaq.ConnectorConfig.FileSettings
  alias Zaq.Event
  alias Zaq.NodeRouter

  def load(socket, request) do
    event = Event.new(request, :channels, opts: [action: :channel_capability_snapshot])
    apply_result(socket, NodeRouter.dispatch(event).response)
  rescue
    _ -> apply_result(socket, {:error, :unavailable})
  catch
    _, _ -> apply_result(socket, {:error, :unavailable})
  end

  def recover(socket, validation) do
    case FileSettings.validation_capabilities(validation) do
      nil -> socket
      result -> apply_result(socket, result)
    end
  end

  def apply_result(socket, {:ok, snapshot}) when is_map(snapshot),
    do: assign(socket, capabilities_snapshot: snapshot, capabilities_error: false)

  def apply_result(socket, _error),
    do: assign(socket, capabilities_snapshot: %{}, capabilities_error: true)
end
