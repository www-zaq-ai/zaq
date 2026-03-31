defmodule Zaq.Hooks.Handler do
  @moduledoc """
  Behaviour contract for ZAQ hook handlers.

  Every hook handler must implement `handle/3`. The return value controls
  how the dispatch chain proceeds:

    * `{:ok, payload}`   — continue chain with (possibly mutated) payload
    * `{:halt, payload}` — stop chain; `dispatch_before` returns `{:halt, payload}`
    * `{:error, term}`   — silently skip this handler, log a warning, continue chain
    * `:ok`              — observer acknowledgement (after hooks); payload unchanged

  ## Hook Events

  ### Agent Pipeline — `Zaq.Agent.Pipeline`

  Context for all pipeline events: `%{trace_id: String.t(), node: node()}`

  #### `:before_retrieval` — `dispatch_before` (sync, mutatable)

  Fired before the knowledge-base retrieval step. Handlers may rewrite the
  question before it reaches the retriever.

      %{
        question: String.t()   # sanitised user question; mutate to override
      }

  #### `:after_retrieval` — `dispatch_after` (async, observer)

  Fired after retrieval succeeds with the raw retrieval result.

      %{
        query:           String.t(),  # generated search query
        language:        String.t(),
        positive_answer: String.t(),  # retriever's positive passage
        negative_answer: String.t()   # retriever's fallback passage
      }

  #### `:before_answering` — `dispatch_before` (sync, mutatable)

  Fired after retrieval and before the LLM answering step. Handlers may
  augment or replace the retrieval payload passed to the answerer.

      %{
        query:           String.t(),
        language:        String.t(),
        positive_answer: String.t(),
        negative_answer: String.t()
      }

  #### `:after_answer_generated` — `dispatch_after` (async, observer)

  Fired immediately after the LLM produces an answer, before pipeline
  post-processing (confidence scoring, no-answer detection).

      %{
        answer: %Zaq.Agent.Answering.Result{}
      }

  #### `:after_pipeline_complete` — `dispatch_after` (async, observer)

  Fired at the very end of a successful pipeline run with the final result
  map returned to the caller.

      %{
        answer:             String.t(),
        confidence_score:   float(),
        latency_ms:         non_neg_integer(),
        prompt_tokens:      non_neg_integer(),
        completion_tokens:  non_neg_integer(),
        total_tokens:       non_neg_integer(),
        error:              false,
        chunks:             [%{"content" => String.t(), "source" => String.t(), "metadata" => map()}]
      }

  `chunks` contains the retrieved chunks used to generate the answer.
  It is `[]` when the pipeline produced no retrieval results.

  ---

  ### Ingestion — `Zaq.Ingestion.Chunk`

  Context for ingestion system events: `%{}`

  #### `:after_embedding_reset` — `dispatch_after` (async, observer)

  Fired after `Chunk.reset_table/1` drops and recreates the chunks table with
  a new embedding dimension. Paid features that maintain their own embedding
  columns should listen to this event to reset and re-embed their data.

      %{
        new_dimension: integer()  # the new embedding vector dimension
      }

  ---

  ### Conversations — `Zaq.Engine.Conversations`

  Context for conversation events: `%{}`

  #### `:feedback_provided` — `dispatch_after` (async, observer)

  Fired after a message rating is created or updated (both positive and
  negative feedback paths). `conversation_history` is always present and
  contains all messages in the conversation ordered by insertion time.

      %{
        message:              %Zaq.Engine.Conversations.Message{},
        rating:               %Zaq.Engine.Conversations.MessageRating{},
        conversation_history: [%Zaq.Engine.Conversations.Message{}],  # mandatory
        rater_attrs:          %{
                                user_id:         Ecto.UUID.t() | nil,
                                channel_user_id: String.t() | nil,
                                rating:          1 | 5,
                                comment:         String.t() | nil
                              }
      }
  """

  @type event :: atom()
  @type payload :: map()
  @type context :: map()

  @callback handle(event(), payload(), context()) ::
              {:ok, payload()}
              | {:halt, payload()}
              | {:error, term()}
              | :ok
end
