defmodule Zaq.Contracts.ToolStep do
  @moduledoc """
  Validated public facts about one tool invocation, separate from private traces.

  `new/1` accepts atom- or string-keyed fields and returns an allowlisted JSON-safe
  map. Invocation identity is required and never truncated. Strings are bounded
  to 256 UTF-8 bytes; display names/labels are safely shortened or use `tool`.
  Sequence is positive and assigned once by the request-local stream owner.

  States are `running`, `succeeded`, `failed`, and `unknown`. The stream owner may
  use `unknown` only when a started invocation has no observed completion outcome
  before request termination. It is not an ambiguous response or inferred failure.
  Correlation belongs in the enclosing message, never in a step. Native result
  interpretation, state transitions, persistence and delivery are not owned here.
  `from_trace/1` normalizes already-authorized display evidence: identifiable
  legacy calls without a recorded outcome display as unknown, never inferred
  success. It does not change the evidence retained for private inspection.
  """

  @states ~w(running succeeded failed unknown)
  @max_bytes 256

  @type t :: %{required(String.t()) => String.t() | non_neg_integer()}

  @doc "Builds a public step, returning a field-specific validation error for invalid facts."
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_id(value(attrs, :id)),
         :ok <- validate_sequence(value(attrs, :sequence)),
         :ok <- validate_kind(value(attrs, :kind)),
         :ok <- validate_state(value(attrs, :state)),
         :ok <- validate_duration(value(attrs, :duration_ms)) do
      name = display(value(attrs, :name), "tool")

      step = %{
        "id" => value(attrs, :id),
        "kind" => "tool",
        "name" => name,
        "label" => display(value(attrs, :label), name),
        "sequence" => value(attrs, :sequence),
        "state" => value(attrs, :state)
      }

      case value(attrs, :duration_ms) do
        nil -> {:ok, step}
        duration -> {:ok, Map.put(step, "duration_ms", duration)}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_step}

  @doc """
  Projects normalized canonical invocation records into ordered public values.

  Records use string keys `invocation_id`, `name`, `sequence`, `outcome` and
  optional `duration_ms`. The Agent owns native event interpretation and outcome
  settlement. Legacy private `id` values are not a public-identity fallback.
  Invalid required facts are excluded; invalid optional durations are omitted.
  Private fields are never copied.
  """
  @spec project(term()) :: [t()]
  def project(calls) when is_list(calls) do
    calls
    |> Enum.flat_map(&project_invocation/1)
    |> Enum.sort_by(& &1["sequence"])
  end

  def project(_calls), do: []

  @doc """
  Projects authorized raw trace entries or already-public steps for display.

  Only raw `tool_call` entries with explicit native invocation identity and a
  positive sequence qualify. A missing legacy outcome becomes `unknown`; an
  explicit invalid outcome remains invalid. Status and response payloads never
  establish outcome or identity. The same allowlist and ordering serve both
  privileged raw traces and ordinary public history without copying private data.
  Normalized runtime calls without a trace type retain their existing projection
  only when they already carry an explicit outcome.
  """
  @spec from_trace(term()) :: [t()]
  def from_trace(trace) when is_list(trace) do
    trace
    |> Enum.flat_map(fn
      %{"type" => "tool_call"} = call ->
        call |> Map.put_new("outcome", "unknown") |> project_invocation()

      %{"type" => _other} ->
        []

      %{"invocation_id" => _, "outcome" => _} = call ->
        project_invocation(call)

      step ->
        public_step(step)
    end)
    |> Enum.sort_by(& &1["sequence"])
  end

  def from_trace(_trace), do: []

  @doc "Validates an already-public snapshot, discarding invalid entries and private extra fields."
  @spec snapshot(term()) :: [t()]
  def snapshot(steps) when is_list(steps) do
    steps
    |> Enum.flat_map(&public_step/1)
    |> Enum.sort_by(& &1["sequence"])
  end

  def snapshot(_steps), do: []

  defp public_step(step) do
    case new(step) do
      {:ok, public} -> [public]
      {:error, _} -> []
    end
  end

  defp project_invocation(call) when is_map(call) do
    attrs = %{
      id: call["invocation_id"],
      kind: "tool",
      name: call["name"],
      sequence: call["sequence"],
      state: call["outcome"],
      duration_ms: optional_duration(call["duration_ms"])
    }

    case new(attrs) do
      {:ok, step} -> [step]
      {:error, _reason} -> []
    end
  end

  defp project_invocation(_call), do: []

  defp optional_duration(duration) when is_integer(duration) and duration >= 0, do: duration
  defp optional_duration(_duration), do: nil

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp validate_id(id) when is_binary(id) do
    if byte_size(id) <= @max_bytes and String.valid?(id) and String.trim(id) != "",
      do: :ok,
      else: {:error, :invalid_id}
  end

  defp validate_id(_id), do: {:error, :invalid_id}

  defp validate_sequence(sequence) when is_integer(sequence) and sequence > 0, do: :ok
  defp validate_sequence(_sequence), do: {:error, :invalid_sequence}

  defp validate_kind("tool"), do: :ok
  defp validate_kind(_kind), do: {:error, :invalid_kind}

  defp validate_state(state) when state in @states, do: :ok
  defp validate_state(_state), do: {:error, :invalid_state}

  defp validate_duration(nil), do: :ok
  defp validate_duration(duration) when is_integer(duration) and duration >= 0, do: :ok
  defp validate_duration(_duration), do: {:error, :invalid_duration}

  defp display(text, fallback) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "" do
      text |> String.codepoints() |> bounded_prefix([], 0)
    else
      fallback
    end
  end

  defp display(_text, fallback), do: fallback

  defp bounded_prefix([point | rest], acc, size) when byte_size(point) + size <= @max_bytes,
    do: bounded_prefix(rest, [point | acc], size + byte_size(point))

  defp bounded_prefix(_rest, acc, _size), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
