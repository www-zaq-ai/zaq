defmodule Zaq.Channels.DeliveryError do
  @moduledoc """
  ZAQ delivery failure facts from attachment selection or a communication bridge.

  `message` is safe for presentation; `reason` retains the original error for
  internal diagnostics and is omitted from inspection. `stage` identifies
  selection, preparation or transport, and `delivery` distinguishes a known unsent
  message from an unconfirmed outcome. These are facts, not retry instructions.
  Channels orchestration owns fallback decisions. Bridges own transport mappings.
  """

  @enforce_keys [:reason, :message, :stage, :delivery]
  @derive {Inspect, only: [:message, :stage, :delivery]}
  defstruct [:reason, :message, :stage, :delivery]

  @type t :: %__MODULE__{
          reason: term(),
          message: String.t(),
          stage: :selection | :preparation | :transport,
          delivery: :not_sent | :unconfirmed
        }
end
