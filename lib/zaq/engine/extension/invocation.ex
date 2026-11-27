defmodule Zaq.Engine.Extension.Invocation do
  @moduledoc """
  An admitted Extension operation carried by a confidential Engine Event.
  Routing identity and trusted execution context are supplied separately by ZAQ.
  """

  @enforce_keys [:operation]
  defstruct [
    :operation,
    :key,
    arguments_json: "{}",
    page_size: 0,
    page_token: "",
    max_json_depth: 32,
    max_result_bytes: 8_388_608
  ]

  @type t :: %__MODULE__{
          operation: :list | :describe | :execute,
          key: String.t() | nil,
          arguments_json: binary(),
          page_size: non_neg_integer(),
          page_token: String.t(),
          max_json_depth: pos_integer(),
          max_result_bytes: pos_integer()
        }
end
