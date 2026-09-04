defmodule Zaq.Materialization.Handler do
  @moduledoc """
  Behaviour for trusted materialization handlers.

  Implementations validate their locator and construct fixed, allowlisted runtime
  calls. A handle selects only the handler type; it never selects an action or
  module directly.
  """

  @callback materialize(locator :: map(), context :: map(), options :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback do_materialize(locator :: map(), context :: map(), options :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback materialization_options() :: [String.t()]

  @optional_callbacks materialization_options: 0
end
