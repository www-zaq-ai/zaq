defmodule Zaq.Hooks.Handler do
  @moduledoc """
  Behaviour contract for ZAQ hook handlers.

  Every hook handler must implement `handle/3`. The return value controls
  how the dispatch chain proceeds:

    * `{:ok, payload}`   — continue chain with (possibly mutated) payload
    * `{:halt, payload}` — stop chain; `dispatch_before` returns `{:halt, payload}`
    * `{:error, term}`   — silently skip this handler, log a warning, continue chain
    * `:ok`              — observer acknowledgement (after hooks); payload unchanged
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
