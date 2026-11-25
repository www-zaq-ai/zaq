defmodule Zaq.Materialization.Sink do
  @moduledoc """
  Consumer-owned write target for materialized content.

  A consumer opens a sink, hands its pid to the producer through trusted event options, and
  the producer appends chunks with `write/2`. The sink process lives on the consumer's node;
  a producer on another node reaches it with a synchronous `GenServer.call`, so only
  bounded chunks cross a node boundary — never a path, a `File.Stream` or an open device.
  Because each write is acknowledged, a producer cannot outrun the consumer: at most one
  chunk is in flight.

  The sink enforces a hard byte quota on the bytes it actually receives (exactly
  `max_bytes` is accepted, one byte more is rejected and nothing of the rejected chunk is
  stored). A size announced with `start/2` only allows early rejection; it is never trusted
  for accounting, so absent, stale or wrong length metadata is covered.

  Modes:

    * `:file` — chunks are appended to a private `.part` file under the given `dir`
    * `:memory` — chunks are kept as iodata and joined by `finish/1` (legacy bytes API)

  The sink monitors its owner. When the owner exits, or on a quota, write or `discard/1`,
  the partial file is closed and removed.

  A finished file is not unowned: after `finish/1` the sink stays alive, still monitoring the
  owner, and removes the file if the owner exits or `discard/1` is called before the caller
  confirms the hand-over with `release/1`. Only `release/1` gives the file up, so there is no
  window in which a completed file exists with nothing responsible for it. With `own_dir: true`
  the whole directory (which the caller must have created for this acquisition alone) is
  cleaned up instead of just the `.part` file, covering a rename into that directory.
  """

  use GenServer

  @type t :: pid()
  @type failure :: {:materialization_limit, pos_integer()} | term()

  @call_timeout :infinity

  # --- client API -------------------------------------------------------------------------

  @doc """
  Opens a sink owned by the calling process (or `:owner`).

  Options: `:mode` (`:file` | `:memory`, required), `:max_bytes` (positive integer,
  required), `:dir` (required for `:file`; created when missing), `:own_dir` (the sink removes
  `:dir` entirely on cleanup; default `false`: only its own `.part` file).
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode)
    max_bytes = Keyword.get(opts, :max_bytes)
    owner = Keyword.get(opts, :owner, self())

    cond do
      mode not in [:file, :memory] ->
        {:error, :invalid_sink_mode}

      not (is_integer(max_bytes) and max_bytes > 0) ->
        {:error, :invalid_sink_quota}

      mode == :file and not is_binary(Keyword.get(opts, :dir)) ->
        {:error, :invalid_sink_dir}

      true ->
        GenServer.start(__MODULE__, %{
          mode: mode,
          max_bytes: max_bytes,
          dir: Keyword.get(opts, :dir),
          own_dir: Keyword.get(opts, :own_dir, false),
          owner: owner
        })
    end
  end

  @doc """
  Marks the start of a body and optionally announces its size.

  Returns `{:error, {:materialization_limit, max}}` when the announced size already exceeds
  the quota. Producers call it once they decide to stream so that an empty source is still
  recognised as materialized.
  """
  @spec start(t(), non_neg_integer() | nil) :: :ok | {:error, failure()}
  def start(sink, declared_size \\ nil), do: call(sink, {:start, declared_size})

  @doc "Returns the byte quota."
  @spec quota(t()) :: pos_integer() | nil
  def quota(sink) do
    case call(sink, :quota) do
      max when is_integer(max) -> max
      _ -> nil
    end
  end

  @doc "Records a failure observed by the producer (e.g. an in-memory cap) and drops partial output."
  @spec fail(t(), failure()) :: :ok
  def fail(sink, failure) do
    case call(sink, {:fail, failure}) do
      :ok -> :ok
      _ -> :ok
    end
  end

  @doc "Declares the output text regardless of its bytes (e.g. a rendered Markdown table)."
  @spec mark_text(t()) :: :ok | {:error, failure()}
  def mark_text(sink), do: call(sink, :mark_text)

  @doc "Appends a chunk. Returns the quota failure without storing the chunk when exceeded."
  @spec write(t(), iodata()) :: :ok | {:error, failure()}
  def write(sink, data), do: call(sink, {:write, data})

  @doc "Returns `%{mode, started?, size, writes, max_chunk, failure}`."
  @spec stats(t()) :: %{
          mode: :file | :memory,
          started?: boolean(),
          size: non_neg_integer(),
          writes: non_neg_integer(),
          max_chunk: non_neg_integer(),
          failure: failure() | nil
        }
  def stats(sink) do
    case call(sink, :stats) do
      %{} = stats ->
        stats

      {:error, reason} ->
        %{mode: nil, started?: false, size: 0, writes: 0, max_chunk: 0, failure: reason}
    end
  end

  @doc """
  Completes the body.

  File mode returns `%{path, size, text?}`; the sink keeps owning the file (see the module
  documentation) until `release/1`. Memory mode returns `%{binary, size, text?}` and stops.
  `text?` is true for valid UTF-8 without NUL bytes.
  """
  @spec finish(t()) :: {:ok, map()} | {:error, failure()}
  def finish(sink), do: call(sink, :finish)

  @doc """
  Confirms that the caller has taken over a finished file and stops the sink without removing
  anything.

  Returns `{:error, :sink_closed}` when the sink is gone, which means it already cleaned up
  (owner exit or `discard/1`): the file must not be used.
  """
  @spec release(t()) :: :ok | {:error, :not_finished | :sink_closed}
  def release(sink), do: call(sink, :release)

  @doc "Closes the sink and removes its partial file. Idempotent."
  @spec discard(t()) :: :ok
  def discard(sink) do
    GenServer.call(sink, :discard, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  defp call(sink, message) do
    GenServer.call(sink, message, @call_timeout)
  catch
    :exit, _ -> {:error, :sink_closed}
  end

  # --- server -----------------------------------------------------------------------------

  @impl true
  def init(%{owner: owner} = opts) do
    ref = Process.monitor(owner)

    state = %{
      mode: opts.mode,
      max_bytes: opts.max_bytes,
      owner_ref: ref,
      started?: false,
      size: 0,
      writes: 0,
      max_chunk: 0,
      failure: nil,
      text?: true,
      forced_text?: false,
      finished?: false,
      carry: <<>>,
      device: nil,
      path: nil,
      parts: []
    }

    {:ok, state |> Map.put(:dir, opts.dir) |> Map.put(:own_dir, opts.own_dir)}
  end

  @impl true
  def handle_call({:start, _declared}, _from, %{finished?: true} = state),
    do: {:reply, {:error, :sink_finished}, state}

  def handle_call({:start, declared}, _from, state) do
    cond do
      state.failure != nil ->
        {:reply, {:error, state.failure}, state}

      is_integer(declared) and declared > state.max_bytes ->
        failed = failed_state(state, limit(state))
        {:reply, {:error, failed.failure}, failed}

      true ->
        case open_storage(state) do
          {:ok, state} ->
            {:reply, :ok, %{state | started?: true}}

          {:error, reason} ->
            failed = failed_state(state, {:sink_write_failed, reason})
            {:reply, {:error, failed.failure}, failed}
        end
    end
  end

  def handle_call({:write, _data}, _from, %{failure: failure} = state) when failure != nil,
    do: {:reply, {:error, failure}, state}

  def handle_call({:write, _data}, _from, %{finished?: true} = state),
    do: {:reply, {:error, :sink_finished}, state}

  def handle_call({:write, data}, _from, state) do
    chunk = IO.iodata_length(data)

    if state.size + chunk > state.max_bytes do
      failed = failed_state(state, limit(state))
      {:reply, {:error, failed.failure}, failed}
    else
      case store(state, data) do
        {:ok, state} ->
          {:reply, :ok,
           classify(
             %{
               state
               | started?: true,
                 size: state.size + chunk,
                 writes: state.writes + 1,
                 max_chunk: max(state.max_chunk, chunk)
             },
             data
           )}

        {:error, reason} ->
          failed = failed_state(state, {:sink_write_failed, reason})
          {:reply, {:error, failed.failure}, failed}
      end
    end
  end

  def handle_call({:fail, failure}, _from, %{failure: nil} = state),
    do: {:reply, :ok, failed_state(state, failure)}

  def handle_call({:fail, _failure}, _from, state), do: {:reply, :ok, state}

  def handle_call(:mark_text, _from, %{failure: failure} = state) when failure != nil,
    do: {:reply, {:error, failure}, state}

  def handle_call(:mark_text, _from, state), do: {:reply, :ok, %{state | forced_text?: true}}

  def handle_call(:quota, _from, state), do: {:reply, state.max_bytes, state}

  def handle_call(:stats, _from, state),
    do:
      {:reply,
       %{
         mode: state.mode,
         started?: state.started?,
         size: state.size,
         writes: state.writes,
         max_chunk: state.max_chunk,
         failure: state.failure
       }, state}

  def handle_call(:finish, _from, %{failure: failure} = state) when failure != nil,
    do: {:stop, :normal, {:error, failure}, discard_storage(state)}

  def handle_call(:finish, _from, %{finished?: true} = state),
    do: {:reply, {:error, :sink_finished}, state}

  def handle_call(:finish, _from, state) do
    text? = state.forced_text? or (state.text? and state.carry == <<>>)

    case finish_storage(state) do
      {:ok, %{path: _} = result} ->
        # The file stays owned by the sink until the caller releases it.
        {:reply, {:ok, Map.merge(result, %{size: state.size, text?: text?})},
         %{state | device: nil, finished?: true}}

      {:ok, result} ->
        {:stop, :normal, {:ok, Map.merge(result, %{size: state.size, text?: text?})},
         discard_storage(state)}

      {:error, reason} ->
        {:stop, :normal, {:error, {:sink_write_failed, reason}}, discard_storage(state)}
    end
  end

  def handle_call(:release, _from, %{finished?: true} = state),
    do: {:stop, :normal, :ok, %{state | path: nil, own_dir: false}}

  def handle_call(:release, _from, state), do: {:reply, {:error, :not_finished}, state}

  def handle_call(:discard, _from, state), do: {:stop, :normal, :ok, discard_storage(state)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, discard_storage(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: discard_storage(state)

  defp limit(state), do: {:materialization_limit, state.max_bytes}

  defp failed_state(state, failure), do: %{discard_storage(state) | failure: failure}

  # --- storage ----------------------------------------------------------------------------

  defp open_storage(%{mode: :memory} = state), do: {:ok, state}
  defp open_storage(%{device: device} = state) when device != nil, do: {:ok, state}

  defp open_storage(%{mode: :file, dir: dir} = state) do
    path = Path.join(dir, "acquisition-#{System.unique_integer([:positive])}.part")

    with :ok <- File.mkdir_p(dir),
         {:ok, device} <- :file.open(String.to_charlist(path), [:write, :raw, :binary]) do
      {:ok, %{state | device: device, path: path}}
    end
  end

  defp store(%{mode: :memory} = state, data), do: {:ok, %{state | parts: [data | state.parts]}}

  defp store(%{mode: :file, device: nil} = state, data) do
    with {:ok, state} <- open_storage(state), do: store(state, data)
  end

  defp store(%{mode: :file, device: device} = state, data) when device != nil do
    case :file.write(device, data) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store(_state, _data), do: {:error, :closed}

  defp finish_storage(%{mode: :memory, parts: parts}),
    do: {:ok, %{binary: parts |> Enum.reverse() |> IO.iodata_to_binary()}}

  defp finish_storage(%{mode: :file, device: nil} = state) do
    with {:ok, state} <- open_storage(state), do: finish_storage(state)
  end

  defp finish_storage(%{mode: :file, device: device, path: path}) do
    case :file.close(device) do
      :ok -> {:ok, %{path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Removes only this sink's own partial file.
  defp discard_storage(%{mode: :file, device: device, path: path} = state) when path != nil do
    if device, do: :file.close(device)
    _ = File.rm(path)
    if state.own_dir, do: File.rm_rf(state.dir)
    %{state | device: nil, path: nil}
  end

  defp discard_storage(%{mode: :file, own_dir: true, dir: dir} = state) when is_binary(dir) do
    _ = File.rm_rf(dir)
    %{state | parts: []}
  end

  defp discard_storage(state), do: %{state | parts: []}

  # --- incremental UTF-8 / NUL classification -----------------------------------------------

  defp classify(%{text?: false} = state, _data), do: state

  defp classify(state, data) do
    binary = join_carry(state.carry, data)

    cond do
      :binary.match(binary, <<0>>) != :nomatch -> %{state | text?: false, carry: <<>>}
      String.valid?(binary) -> %{state | carry: <<>>}
      true -> carry_incomplete(state, binary)
    end
  end

  defp join_carry(<<>>, data) when is_binary(data), do: data
  defp join_carry(carry, data), do: carry <> IO.iodata_to_binary(data)

  # A chunk boundary may split a multi-byte character: hold back up to 3 trailing bytes.
  defp carry_incomplete(state, binary) do
    size = byte_size(binary)

    Enum.find_value(1..min(3, size)//1, %{state | text?: false, carry: <<>>}, fn n ->
      if String.valid?(binary_part(binary, 0, size - n)),
        do: %{state | carry: binary_part(binary, size - n, n)}
    end)
  end
end
