defmodule Zaq.Materialization.JsonArrayRows do
  @moduledoc """
  Incrementally decodes a top-level JSON array and renders its rows as Markdown.

  Provider responses that `Req` would decode into a list of rows are converted by ingestion to a
  Markdown table. Doing that without holding the whole array uses the standard library's
  resumable decoder (`:json.decode_start/3`, `:json.decode_continue/2`): only the top-level
  array's `array_push` is intercepted, so each completed element is rendered by
  `Zaq.Materialization.RowsMarkdown` (the same conversion ingestion applies to a decoded list)
  and handed to `emit`, then dropped. Everything inside an element decodes exactly as the
  default decoder does (objects to string-keyed maps, `null` to `nil`).

  Memory is bounded by one element, not by the array: `max_element_bytes` limits the raw bytes
  fed since the last completed element (to within one chunk).
  """

  alias Zaq.Materialization.RowsMarkdown

  @type emit :: (iodata() -> :ok | {:error, term()})
  @type t :: %__MODULE__{
          emit: emit(),
          decoder: term(),
          pending: non_neg_integer(),
          max_element_bytes: pos_integer(),
          counter: :counters.counters_ref(),
          done?: boolean()
        }

  defstruct [:emit, :decoder, :max_element_bytes, :counter, pending: 0, done?: false]

  @doc "Creates a decoder that passes rendered rows to `emit`."
  @spec new(emit(), pos_integer()) :: t()
  def new(emit, max_element_bytes) when is_function(emit, 1) and max_element_bytes > 0 do
    %__MODULE__{emit: emit, max_element_bytes: max_element_bytes, counter: :counters.new(2, [])}
  end

  @doc """
  Feeds the next chunk of the body.

  Returns `{:error, {:materialization_limit, max}}` when one element exceeds the bound,
  `{:error, :invalid_json}` for malformed JSON or anything after the array, or the error
  returned by `emit`.
  """
  @spec feed(t(), binary()) :: {:ok, t()} | {:error, term()}
  def feed(%__MODULE__{done?: true} = state, chunk) do
    if blank?(chunk), do: {:ok, state}, else: {:error, :invalid_json}
  end

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    :counters.add(state.counter, 1, byte_size(chunk))

    with {:ok, state} <- state |> advance(chunk) |> settle(state) do
      if :counters.get(state.counter, 1) > state.max_element_bytes,
        do: {:error, {:materialization_limit, state.max_element_bytes}},
        else: {:ok, state}
    end
  end

  @doc "Number of rows rendered so far."
  @spec rows(t()) :: non_neg_integer()
  def rows(%__MODULE__{counter: counter}), do: :counters.get(counter, 2)

  @doc "Ends the body; the array must have been closed."
  @spec finish(t()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{done?: true} = state), do: {:ok, state}
  def finish(%__MODULE__{decoder: nil}), do: {:error, :invalid_json}

  def finish(%__MODULE__{} = state) do
    state |> advance(:end_of_input) |> settle(state)
  end

  defp advance(%__MODULE__{decoder: nil, emit: emit, counter: counter}, chunk),
    do: guarded(fn -> :json.decode_start(chunk, :root, decoders(emit, counter)) end)

  defp advance(%__MODULE__{decoder: decoder}, input),
    do: guarded(fn -> :json.decode_continue(input, decoder) end)

  defp settle({:continue, decoder}, state), do: {:ok, %{state | decoder: decoder}}

  defp settle({:rows_done, :root, rest}, state) do
    if blank?(rest), do: {:ok, %{state | done?: true}}, else: {:error, :invalid_json}
  end

  defp settle({:error, _reason} = error, _state), do: error
  defp settle(_other, _state), do: {:error, :invalid_json}

  # Decoder errors are raised (`:json` signals bad input with `error/1`); callbacks abort with a
  # throw carrying the emit failure.
  defp guarded(fun) do
    fun.()
  catch
    {:rows_emit_failed, reason} -> {:error, reason}
    :error, _reason -> {:error, :invalid_json}
  end

  defp decoders(emit, counter) do
    %{
      null: nil,
      array_start: fn
        :root -> {:rows, RowsMarkdown.new()}
        _parent -> []
      end,
      array_push: fn
        value, {:rows, rendering} -> push(emit, counter, value, rendering)
        value, acc -> [value | acc]
      end,
      array_finish: fn
        {:rows, _rendering}, parent -> {:rows_done, parent}
        acc, parent -> {:lists.reverse(acc), parent}
      end
    }
  end

  defp push(emit, counter, value, rendering) do
    {iodata, rendering} = RowsMarkdown.push(rendering, value)

    case emit.(iodata) do
      :ok ->
        :counters.put(counter, 1, 0)
        :counters.add(counter, 2, 1)
        {:rows, rendering}

      {:error, reason} ->
        throw({:rows_emit_failed, reason})
    end
  end

  defp blank?(binary), do: String.match?(binary, ~r/\A[ \t\r\n]*\z/)
end
