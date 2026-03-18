defmodule Zaq.Engine.RetrievalChannel do
  @moduledoc """
  Behaviour contract for retrieval channel adapters.

  A retrieval channel is a messaging platform through which users submit
  questions and receive answers from ZAQ's agent pipeline.

  ## Examples of adapters
  - `Zaq.Channels.Retrieval.Mattermost`
  - `Zaq.Channels.Retrieval.Slack`
  - `Zaq.Channels.Retrieval.Email`

  ## Message flow

      External platform
        → handle_event/1        # adapter receives raw platform event
        → forward_to_engine/1   # adapter hands off parsed question to Engine
        → Engine routes to Agent pipeline
        → send_message/3        # adapter delivers answer back to platform
  """

  @type config :: map()
  @type state :: any()
  @type channel_id :: String.t()
  @type thread_id :: String.t() | nil
  @type message :: String.t()

  @doc """
  Connects to the messaging platform and returns an opaque state used by
  subsequent callbacks.
  """
  @callback connect(config()) :: {:ok, state()} | {:error, term()}

  @doc """
  Disconnects from the messaging platform and releases any held resources.
  """
  @callback disconnect(state()) :: :ok

  @doc """
  Sends a message to a channel, optionally within a thread.
  """
  @callback send_message(channel_id(), message(), thread_id()) ::
              :ok | {:error, term()}

  @doc """
  Sends a question to a channel and returns a platform post ID for reply tracking.

  Used by `Zaq.Engine.Router` when a feature needs to dispatch a question and
  await a reply via `Zaq.Channels.PendingQuestions`. Distinct from `send_message/3`,
  which is fire-and-forget for delivering answers.

  Implementing adapters must also call `PendingQuestions.check_reply/1` in their
  inbound event handler so that threaded replies are matched back to the callback.
  """
  @callback send_question(channel_id(), message()) ::
              {:ok, post_id :: String.t()} | {:error, term()}

  @doc """
  Handles a raw incoming event from the platform.
  Adapters are responsible for parsing the event and deciding whether
  to call `forward_to_engine/1`.
  """
  @callback handle_event(event :: map()) :: :ok | {:error, term()}

  @doc """
  Forwards a parsed question to the Engine for routing to the Agent pipeline.
  Called by the adapter after `handle_event/1` determines the event is a
  user question.

  The `question` map must include at minimum:
  - `:text`       — the raw question string
  - `:channel_id` — where to deliver the answer
  - `:user_id`    — who asked the question

  Optional fields:
  - `:thread_id`  — thread to reply into (if platform supports threading)
  - `:metadata`   — any adapter-specific context
  """
  @callback forward_to_engine(
              question :: %{
                required(:text) => String.t(),
                required(:channel_id) => channel_id(),
                required(:user_id) => String.t(),
                optional(:thread_id) => thread_id(),
                optional(:metadata) => map()
              }
            ) :: :ok | {:error, term()}
end
