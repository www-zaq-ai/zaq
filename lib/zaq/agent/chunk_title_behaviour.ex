defmodule Zaq.Agent.ChunkTitleBehaviour do
  @moduledoc """
  Behaviour for chunk title generation.

  Allows swapping the real LLM-backed implementation with a mock in tests.
  """

  @callback ask(content :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
