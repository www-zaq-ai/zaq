defmodule Zaq.Channels.EmailBridge.ImapAdapter.Listener do
  @moduledoc """
  One mailbox-scoped IMAP listener process.

  Each runtime mailbox gets a dedicated listener GenServer. The listener owns
  one IMAP client connection and loops through this lifecycle:

  1. connect to mailbox
  2. optionally fetch initial unread messages
  3. enter IMAP IDLE
  4. on `:idle_notify`, fetch unseen messages and re-enter IDLE

  Error handling keeps the process alive and self-healing: failed connects,
  fetch errors, stale client pids, and IDLE re-entry failures all clear the
  client and schedule reconnect with `retry_interval`.
  """

  use GenServer

  require Logger

  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Utils.ParseUtils

  @default_retry_interval 30_000

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.fetch!(opts, :config)
    mailbox = Keyword.fetch!(opts, :mailbox)
    sink_mfa = Keyword.fetch!(opts, :sink_mfa)
    sink_opts = Keyword.get(opts, :sink_opts, [])

    state = %{
      config: config,
      bridge_id: Keyword.fetch!(opts, :bridge_id),
      mailbox: mailbox,
      sink_mfa: sink_mfa,
      sink_opts: sink_opts,
      client: nil,
      imap_adapter: Keyword.get(opts, :imap_adapter, ImapAdapter),
      retry_interval: Keyword.get(opts, :retry_interval, retry_interval(config)),
      mark_as_read: Keyword.get(opts, :mark_as_read, mark_as_read?(config)),
      load_initial_unread: Keyword.get(opts, :load_initial_unread, load_initial_unread?(config)),
      idle_timeout: Keyword.get(opts, :idle_timeout, idle_timeout(config))
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    {:noreply, connect_and_idle(state)}
  end

  def handle_info(:idle_notify, state) do
    state =
      state
      |> fetch_unseen_and_maybe_mark_read()
      |> maybe_reenter_idle()

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{client: pid} = state) do
    Logger.warning(
      "[EmailBridge.ImapListener] IMAP client exited bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
    )

    schedule_reconnect(state.retry_interval)
    {:noreply, %{state | client: nil}}
  end

  def handle_info(:reconnect, state), do: {:noreply, connect_and_idle(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{client: client} = state) when is_pid(client) do
    state_adapter(state).disconnect(client)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect_and_idle(state) do
    case state_adapter(state).connect(state.config, state.mailbox) do
      {:ok, client} ->
        state = %{state | client: client}
        state = maybe_fetch_initial_unread(state)
        maybe_reenter_idle(state)

      {:error, reason} ->
        Logger.warning(
          "[EmailBridge.ImapListener] connect failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
        )

        schedule_reconnect(state.retry_interval)
        state
    end
  end

  defp fetch_unseen_and_maybe_mark_read(%{client: nil} = state), do: state

  defp fetch_unseen_and_maybe_mark_read(state) do
    case safe_fetch_unseen(
           state_adapter(state),
           state.client,
           state.mailbox,
           &handle_message(state, &1)
         ) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning(
          "[EmailBridge.ImapListener] fetch unseen failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
        )

        schedule_reconnect(state.retry_interval)
        %{state | client: nil}
    end
  end

  defp maybe_reenter_idle(%{client: client} = state) when is_pid(client) do
    if Process.alive?(client) do
      case safe_enter_idle(state_adapter(state), client, state.idle_timeout) do
        :ok ->
          state

        {:error, reason} ->
          Logger.warning(
            "[EmailBridge.ImapListener] IDLE re-entry failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
          )

          schedule_reconnect(state.retry_interval)
          %{state | client: nil}
      end
    else
      Logger.warning(
        "[EmailBridge.ImapListener] stale IMAP client before IDLE bridge_id=#{state.bridge_id} mailbox=#{state.mailbox}"
      )

      schedule_reconnect(state.retry_interval)
      %{state | client: nil}
    end
  end

  defp maybe_reenter_idle(state), do: state

  defp safe_fetch_unseen(adapter, client, mailbox, on_message) do
    adapter.fetch_unseen(client, mailbox, on_message)
  rescue
    error -> {:error, {:imap_fetch_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:imap_fetch_failed, reason}}
  end

  defp safe_enter_idle(adapter, client, idle_timeout) do
    adapter.enter_idle(client, idle_timeout)
  rescue
    error -> {:error, {:imap_idle_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:imap_idle_failed, reason}}
  end

  defp handle_message(state, message) do
    dispatch_to_sink(state, message)
    maybe_mark_as_read(state, message)
  end

  defp dispatch_to_sink(state, message) do
    {mod, fun, extra_args} = state.sink_mfa

    apply(mod, fun, [
      state.config,
      message,
      Keyword.put(state.sink_opts, :mailbox, state.mailbox) | extra_args
    ])
  rescue
    error ->
      Logger.warning(
        "[EmailBridge.ImapListener] sink dispatch failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{Exception.message(error)}"
      )
  end

  defp maybe_mark_as_read(%{mark_as_read: false}, _message), do: :ok

  defp maybe_mark_as_read(state, message) do
    case Map.get(message, "seq") do
      seq when is_integer(seq) -> state_adapter(state).mark_as_read(state.client, seq)
      _ -> :ok
    end
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[EmailBridge.ImapListener] mark-as-read failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
        )
    end
  end

  defp mark_as_read?(config) do
    config_get(config, :mark_as_read, true) != false
  end

  defp load_initial_unread?(config) do
    config_get(config, :load_initial_unread, false) == true
  end

  defp maybe_fetch_initial_unread(%{load_initial_unread: true} = state),
    do: fetch_unseen_and_maybe_mark_read(state)

  defp maybe_fetch_initial_unread(state), do: state

  defp retry_interval(config) do
    value = config_get(config, :poll_interval, @default_retry_interval)

    ParseUtils.parse_positive_int(value, @default_retry_interval)
  end

  defp idle_timeout(config) do
    ParseUtils.parse_positive_int(config_get(config, :idle_timeout), 1_500_000)
  end

  defp config_get(config, key, default \\ nil)

  defp config_get(config, key, default) when is_map(config) and is_atom(key) do
    case Map.get(config, key) do
      nil -> Map.get(config, Atom.to_string(key), default)
      value -> value
    end
  end

  defp config_get(_config, _key, default), do: default

  defp schedule_reconnect(interval), do: Process.send_after(self(), :reconnect, interval)

  defp state_adapter(%{imap_adapter: adapter}) when is_atom(adapter), do: adapter
  defp state_adapter(_state), do: ImapAdapter
end
