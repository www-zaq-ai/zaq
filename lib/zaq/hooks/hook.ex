defmodule Zaq.Hooks.Hook do
  @moduledoc """
  Struct representing a registered ZAQ hook.

  Fields:

    * `:handler`   — module implementing `Zaq.Hooks.Handler`
    * `:events`    — list of event atoms this hook subscribes to
    * `:mode`      — `:sync` (mutates payload, can halt) or `:async` (fire-and-forget)
    * `:node_role` — target role for async dispatch via `NodeRouter`; `:local` spawns a Task
    * `:priority`  — lower numbers run first (default `50`); only meaningful for `:before_*` sync hooks
  """

  @enforce_keys [:handler, :events, :mode]

  defstruct [
    :handler,
    :events,
    :mode,
    node_role: :local,
    priority: 50
  ]

  @type t :: %__MODULE__{
          handler: module(),
          events: [atom()],
          mode: :sync | :async,
          node_role: :local | :agent | :ingestion | :channels | :engine | :bo,
          priority: non_neg_integer()
        }
end
