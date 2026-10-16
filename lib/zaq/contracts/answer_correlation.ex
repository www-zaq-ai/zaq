defmodule Zaq.Contracts.AnswerCorrelation do
  @moduledoc """
  Public correlation for one selected Engine-owned assistant answer.

  `request_id` identifies the submission; `root_request_id` identifies the request
  producing the shared answer. Queued submissions may therefore share an
  `assistant_message_id` without sharing their request or canonical input UUID.

  Construction validates shape only: it allocates nothing and grants no authority.
  A reserved assistant UUID is not evidence of persistence, delivery or history
  association. Execution capabilities and provider edit handles travel separately.
  Legacy events without a selected answer are not this contract; consumers retain
  their explicit legacy receive path rather than inventing a canonical identity.
  """

  @fields [:assistant_message_id, :user_message_id, :request_id, :root_request_id]
  @keys Enum.map(@fields, &Atom.to_string/1)
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          assistant_message_id: Ecto.UUID.t(),
          user_message_id: Ecto.UUID.t(),
          request_id: String.t(),
          root_request_id: String.t()
        }

  @doc "Validates a complete atom- or string-keyed correlation, rejecting extra or ambiguous keys."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_answer_correlation}
  def new(attrs) when is_map(attrs) and map_size(attrs) == 4 do
    values = Map.new(@fields, &{&1, Map.get(attrs, &1, Map.get(attrs, Atom.to_string(&1)))})

    with true <- Enum.all?(Map.keys(attrs), &(&1 in @fields or &1 in @keys)),
         true <- canonical_uuid?(values.assistant_message_id),
         true <- canonical_uuid?(values.user_message_id),
         true <- values.assistant_message_id != values.user_message_id,
         true <- request_id?(values.request_id) and request_id?(values.root_request_id) do
      {:ok, struct!(__MODULE__, values)}
    else
      _ -> {:error, :invalid_answer_correlation}
    end
  end

  def new(_), do: {:error, :invalid_answer_correlation}

  @doc "Projects only public correlation fields using stable JSON keys."
  @spec to_map(t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{} = correlation),
    do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(correlation, &1)})

  defp canonical_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> true
      _ -> false
    end
  end

  defp canonical_uuid?(_), do: false

  defp request_id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
