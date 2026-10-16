defmodule Zaq.Engine.Events do
  @moduledoc """
  Standardized Engine role event builders and dispatchers.
  """

  alias Zaq.Event
  alias Zaq.Events.Helper

  @doc "Reads one authorized canonical message through the existing conversation boundary."
  @spec build_and_dispatch_canonical_message_event(String.t(), String.t(), keyword()) :: Event.t()
  def build_and_dispatch_canonical_message_event(transcript_id, message_id, opts \\ []) do
    router = Keyword.get(opts, :node_router, Zaq.NodeRouter)

    Event.new(
      %{action: :canonical_message, transcript_id: transcript_id, message_id: message_id},
      :engine,
      actor: Keyword.get(opts, :actor),
      opts: [action: :conversation, confidential: true]
    )
    |> router.dispatch()
  end

  @spec build_invoke_event(map(), atom(), keyword()) :: Event.t()
  def build_invoke_event(request, action, opts \\ []) when is_map(request) and is_atom(action) do
    Helper.build_invoke_event(:engine, request, action, opts)
  end

  @spec build_and_dispatch_invoke_event(map(), atom(), keyword()) :: Event.t()
  def build_and_dispatch_invoke_event(request, action, opts \\ [])
      when is_map(request) and is_atom(action) do
    Helper.build_and_dispatch_invoke_event(:engine, request, action, opts)
  end
end
