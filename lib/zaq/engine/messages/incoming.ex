defmodule Zaq.Engine.Messages.Incoming do
  @moduledoc """
  Canonical internal message struct for all inbound messages crossing the adapter boundary.

  Every channel adapter (Mattermost, Slack, HTTP, etc.) must map its transport-specific
  payload to this struct before passing a message to any ZAQ component (Pipeline, Bridge,
  Conversations, etc.). Nothing inside ZAQ should depend on adapter-specific envelope types.
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
    metadata: %{}
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
          metadata: map()
        }
end
