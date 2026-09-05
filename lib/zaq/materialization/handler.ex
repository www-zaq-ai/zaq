defmodule Zaq.Materialization.Handler do
  @moduledoc """
  Behaviour for trusted materialization handlers.

  Implementations validate their locator and construct fixed, allowlisted runtime
  calls. A handle selects only the handler type; it never selects an action or
  module directly.

  Runtime options are JSON-compatible maps with string keys. Callers at
  non-serialized boundaries must normalize atom-keyed input before calling
  `Zaq.Materialization.materialize/4` or handler `materialize/3` functions.
  """

  @callback materialize(
              locator :: map(),
              context :: map(),
              options :: %{optional(String.t()) => term()}
            ) ::
              {:ok, map()} | {:error, term()}

  @callback do_materialize(
              locator :: map(),
              context :: map(),
              options :: %{optional(String.t()) => term()}
            ) ::
              {:ok, map()} | {:error, term()}

  @doc "Returns the allowed JSON-compatible string option keys for this materializer."
  @callback materialization_options() :: [String.t()]

  @optional_callbacks materialization_options: 0
end
