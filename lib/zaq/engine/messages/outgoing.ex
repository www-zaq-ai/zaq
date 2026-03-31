defmodule Zaq.Engine.Messages.Outgoing do
  @moduledoc """
  Canonical internal struct for all outbound messages crossing the adapter boundary.

  Produced by `Zaq.Agent.Pipeline.run/2` and by the Notification center.
  Delivered via `Zaq.Channels.Router.deliver/1`, which resolves the correct bridge
  and calls `bridge.send_reply/2`.

  Nothing inside ZAQ should depend on adapter-specific envelope types — all outbound
  delivery flows through this struct.
  """

  alias Zaq.Engine.Messages.Incoming

  @enforce_keys [:body, :channel_id, :provider]

  defstruct [
    :body,
    :channel_id,
    :thread_id,
    :author_id,
    :author_name,
    :provider,
    :in_reply_to,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          body: String.t(),
          channel_id: String.t(),
          thread_id: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          provider: atom() | String.t(),
          in_reply_to: String.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an `%Outgoing{}` from an `%Incoming{}` and the pipeline result map.

  Copies routing fields (channel_id, thread_id, author_id, author_name, provider) from
  the incoming message, sets `body` from `result.answer`, and stores the full result map
  in `metadata` (answer, confidence_score, latency_ms, tokens, error).
  """
  @spec from_pipeline_result(Incoming.t(), map()) :: t()
  def from_pipeline_result(%Incoming{} = incoming, result) when is_map(result) do
    %__MODULE__{
      body: result.answer,
      channel_id: incoming.channel_id,
      thread_id: incoming.thread_id,
      author_id: incoming.author_id,
      author_name: incoming.author_name,
      provider: incoming.provider,
      in_reply_to: incoming.message_id,
      metadata: Map.merge(incoming.metadata, result)
    }
  end
end
