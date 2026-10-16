defmodule Zaq.Contracts.AnswerOutcome do
  @moduledoc """
  Bounded public facts about submission, execution and answer placement.

  Each dimension is independent: accepting a submission does not prove its input
  was consumed, completing execution does not prove delivery, and reserving an
  answer does not create history. `execution: \"unknown\"` is an observation after
  lost contact, never a persisted terminal execution status or permission to retry.

  Engine roots retain pending/completed/failed storage states. Suppressed and
  cancelled dispositions are recorded in their bounded private outcome; receipt
  consumption retains queued/consumed/unconsumed storage states. This value does
  not implement transitions, authorize access or publish events. Owning services
  construct it from evidence, not from the presence of an identifier.
  """

  @values %{
    submission: ~w(accepted rejected),
    input: ~w(not_applicable queued consumed unconsumed),
    execution: ~w(not_started running completed suppressed failed cancelled unknown),
    persistence: ~w(not_persisted persisted unknown),
    delivery: ~w(not_attempted confirmed failed unknown),
    history: ~w(not_associated associated unknown)
  }
  @fields Map.keys(@values)
  @keys Enum.map(@fields, &Atom.to_string/1)
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          submission: String.t(),
          input: String.t(),
          execution: String.t(),
          persistence: String.t(),
          delivery: String.t(),
          history: String.t()
        }

  @doc "Validates complete public facts without inferring outcomes from other dimensions."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_answer_outcome}
  def new(attrs) when is_map(attrs) and map_size(attrs) == 6 do
    values = Map.new(@fields, &{&1, Map.get(attrs, &1, Map.get(attrs, Atom.to_string(&1)))})

    with true <- Enum.all?(Map.keys(attrs), &(&1 in @fields or &1 in @keys)),
         true <- Enum.all?(@values, fn {key, allowed} -> values[key] in allowed end),
         true <- consistent?(values) do
      {:ok, struct!(__MODULE__, values)}
    else
      _ -> {:error, :invalid_answer_outcome}
    end
  end

  def new(_), do: {:error, :invalid_answer_outcome}

  @doc "Projects the outcome allowlist with stable string keys and values."
  @spec to_map(t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{} = outcome),
    do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(outcome, &1)})

  defp consistent?(%{submission: "rejected"} = values) do
    values.input == "not_applicable" and values.execution == "not_started" and
      values.persistence == "not_persisted" and values.delivery == "not_attempted" and
      values.history == "not_associated"
  end

  defp consistent?(values) do
    (values.persistence != "persisted" or values.execution == "completed") and
      (values.history != "associated" or values.persistence == "persisted")
  end
end
