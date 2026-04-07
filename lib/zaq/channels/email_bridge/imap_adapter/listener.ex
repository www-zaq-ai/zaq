defmodule Zaq.Channels.EmailBridge.ImapAdapter.Listener do
  @moduledoc false

  use GenServer

  require Logger

  alias Zaq.Channels.{ChannelConfig, EmailBridge.ImapAdapter}

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
      retry_interval: retry_interval(config),
      mark_as_read: mark_as_read?(config)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    {:noreply, connect_and_idle(state)}
  end

  def handle_info(:idle_notify, state) do
    state = fetch_unseen_and_maybe_mark_read(state)
    if is_pid(state.client), do: :ok = ImapAdapter.enter_idle(state.client, state.config)
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
  def terminate(_reason, %{client: client}) when is_pid(client) do
    ImapAdapter.disconnect(client)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect_and_idle(state) do
    case ImapAdapter.connect(state.config, state.mailbox) do
      {:ok, client} ->
        state = %{state | client: client}
        state = fetch_unseen_and_maybe_mark_read(state)
        :ok = ImapAdapter.enter_idle(client, state.config)
        state

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
    case ImapAdapter.fetch_unseen(state.client, state.mailbox, &handle_message(state, &1)) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning(
          "[EmailBridge.ImapListener] fetch unseen failed bridge_id=#{state.bridge_id} mailbox=#{state.mailbox} reason=#{inspect(reason)}"
        )

        state
    end
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
      seq when is_integer(seq) -> ImapAdapter.mark_as_read(state.client, seq)
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
    config
    |> ChannelConfig.imap_settings()
    |> Map.get("mark_as_read", true)
    |> Kernel.!=(false)
  end

  defp retry_interval(config) do
    value =
      config
      |> ChannelConfig.imap_settings()
      |> Map.get("poll_interval", @default_retry_interval)

    case value do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @default_retry_interval
        end

      _ ->
        @default_retry_interval
    end
  end

  defp schedule_reconnect(interval), do: Process.send_after(self(), :reconnect, interval)
end
