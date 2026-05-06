defmodule Zaq.Agent.Answering.Result do
  @moduledoc """
  Canonical answer result returned by answering modules.

  This struct standardizes answer payloads across channels and callers.
  """

  @type t :: %__MODULE__{
          answer: String.t(),
          clarification: String.t() | nil,
          confidence_score: float() | nil,
          latency_ms: integer() | nil,
          prompt_tokens: integer() | nil,
          completion_tokens: integer() | nil,
          total_tokens: integer() | nil
        }

  @enforce_keys [:answer]
  defstruct [
    :answer,
    :clarification,
    :confidence_score,
    :latency_ms,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens
  ]
end
