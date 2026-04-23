defmodule Zaq.Engine.Messages.Incoming do
  @moduledoc """
  Canonical inbound message payload struct.

  Every channel adapter (Mattermost, Slack, HTTP, etc.) must map its transport-specific
  payload to this struct before passing a message to any ZAQ component (Pipeline, Bridge,
  Conversations, etc.). Nothing inside ZAQ should depend on adapter-specific envelope types.

  For cross-node routing, this struct is wrapped by `%Zaq.Event{request: %Incoming{...}}`.
  """

  @enforce_keys [:content, :channel_id, :provider]

  defstruct [
    :content,
    :channel_id,
    :author_id,
    :author_name,
    :thread_id,
    :message_id,
    :provider,
    :person_id,
    is_dm: false,
    metadata: %{},
    content_filter: []
  ]

  @type t :: %__MODULE__{
          content: String.t(),
          channel_id: String.t(),
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          thread_id: String.t() | nil,
          message_id: String.t() | nil,
          provider: atom() | String.t(),
          person_id: integer() | nil,
          is_dm: boolean(),
          metadata: map(),
          content_filter: [String.t()]
        }
end
