defmodule Zaq.Materialization.Handler do
  @moduledoc """
  Behaviour for trusted materialization handlers.

  Implementations validate their locator and construct fixed, allowlisted runtime
  calls. A handle selects only the handler type; it never selects an action or
  module directly.
  """

  @callback materialize(locator :: map(), context :: map(), options :: map()) ::
              {:ok, map()} | {:error, term()}
end
