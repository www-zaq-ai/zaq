defmodule Zaq.Engine.Messages.Outgoing do
  @moduledoc """
  Canonical outbound message payload struct.

  Produced by configured-agent execution and by the Notification center.
  Delivered through `Zaq.NodeRouter.dispatch/1` to `Zaq.Channels.Api`
  (action `:deliver_outgoing`), which resolves the provider bridge
  and calls `bridge.send_reply/2`.

  Nothing inside ZAQ should depend on adapter-specific envelope types — all outbound
  delivery flows through this struct.

  `attachments` contains explicitly requested `Zaq.Contracts.Record` values. Incoming
  attachments are never automatically echoed, and runtime attachment collections
  are excluded from metadata.
  `attachment_error` carries a rejected selection independently of answer success,
  so Channels can report it through the delivery policy.

  `thread_anchor` is the opaque prior-thread anchor resolved by the notification
  center (string keys: `"message_id"`, `"references"`, `"thread_id"`). It is
  interpreted only by the provider bridge; bridges that do not thread ignore it.

  For cross-node routing, this struct is typically carried in `%Zaq.Event.response`.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  @enforce_keys [:body, :channel_id, :provider]

  defstruct [
    :body,
    :channel_id,
    :thread_id,
    :author_id,
    :author_name,
    :provider,
    :in_reply_to,
    :thread_anchor,
    :attachment_error,
    attachments: [],
    routing_context: %RoutingContext{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          body: String.t(),
          channel_id: String.t(),
          thread_id: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          provider: atom() | String.t(),
          in_reply_to: String.t() | integer() | nil,
          thread_anchor: map() | nil,
          attachments: [Record.t()],
          attachment_error: :invalid_attachment_selection | nil,
          routing_context: RoutingContext.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an `%Outgoing{}` from an `%Incoming{}` and the pipeline result map.

  Copies routing fields (channel_id, thread_id, author_id, author_name, provider) from
  the incoming message, sets `body` from `result.answer`, and merges result metadata
  (answer, confidence_score, latency_ms, tokens, error).

  Copies atom-keyed `result.attachments` unchanged, defaulting to `[]` when omitted.
  Producers own the Record contract; Channels validates attachments during delivery.
  Attachment keys are excluded from merged metadata, including any incoming values.
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
      attachments: Map.get(result, :attachments, []),
      attachment_error: Map.get(result, :attachment_error),
      routing_context: incoming.routing_context,
      metadata:
        incoming.metadata
        |> Map.merge(result)
        |> Map.drop([:attachments, "attachments", :attachment_error, "attachment_error"])
        |> put_person(incoming.person)
    }
  end

  defp put_person(metadata, nil), do: metadata
  defp put_person(metadata, person), do: Map.put(metadata, :person, person)
end
