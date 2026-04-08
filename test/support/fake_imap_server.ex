defmodule Zaq.TestSupport.FakeImapServer do
  use GenServer

  @moduledoc """
  In-memory fake IMAP server used by tests.
  """

  @command_atoms %{
    "LOGIN" => :login,
    "SELECT" => :select,
    "LIST" => :list,
    "SEARCH" => :search,
    "FETCH" => :fetch,
    "STORE" => :store,
    "IDLE" => :idle,
    "LOGOUT" => :logout
  }

  @default_message %{
    uid: 101,
    subject: "Support request",
    from_name: "Alice",
    from_mailbox: "alice",
    from_host: "example.com",
    message_id: "<msg-101@example.com>",
    in_reply_to: "<thread-root@example.com>",
    references: "<thread-root@example.com>",
    rfc822: "RAW RFC822 MESSAGE"
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def endpoint(pid) when is_pid(pid) do
    GenServer.call(pid, :endpoint)
  end

  def config(pid, overrides \\ %{}) when is_pid(pid) and is_map(overrides) do
    %{host: host, port: port} = endpoint(pid)

    Map.merge(
      %{
        url: "imap://#{host}:#{port}",
        username: "demo",
        password: "secret",
        ssl: false,
        timeout: 1_500
      },
      overrides
    )
  end

  def trigger_exists(pid, count \\ 2) when is_pid(pid) and is_integer(count) do
    GenServer.call(pid, {:trigger_exists, count})
  end

  def commands(pid) when is_pid(pid) do
    GenServer.call(pid, :commands)
  end

  def seen?(pid) when is_pid(pid) do
    GenServer.call(pid, :seen)
  end

  @impl GenServer
  def init(opts) do
    owner = Keyword.get(opts, :owner)
    mailboxes = Keyword.get(opts, :mailboxes, ["INBOX"])
    message = Map.merge(@default_message, Keyword.get(opts, :message, %{}))
    seen = Keyword.get(opts, :seen, false)
    list_mode = Keyword.get(opts, :list_mode, :ok)
    fetch_mode = Keyword.get(opts, :fetch_mode, :ok)
    include_envelope = Keyword.get(opts, :include_envelope, true)
    include_header = Keyword.get(opts, :include_header, true)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, :line},
        {:active, false},
        {:reuseaddr, true},
        {:ip, {127, 0, 0, 1}}
      ])

    {:ok, {_ip, port}} = :inet.sockname(listen_socket)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(listen_socket, server) end)
    :ok = :gen_tcp.controlling_process(listen_socket, acceptor)

    {:ok,
     %{
       owner: owner,
       host: "127.0.0.1",
       port: port,
       listen_socket: listen_socket,
       acceptor: acceptor,
       mailboxes: mailboxes,
       message: message,
       seen: seen,
       list_mode: list_mode,
       fetch_mode: fetch_mode,
       include_envelope: include_envelope,
       include_header: include_header,
       command_log: [],
       connections: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_call(:endpoint, _from, state) do
    {:reply, %{host: state.host, port: state.port}, state}
  end

  def handle_call(:commands, _from, state) do
    {:reply, Enum.reverse(state.command_log), state}
  end

  def handle_call(:seen, _from, state) do
    {:reply, state.seen, state}
  end

  def handle_call({:trigger_exists, count}, _from, state) do
    Enum.each(state.connections, fn pid -> send(pid, {:notify_exists, count}) end)
    {:reply, :ok, state}
  end

  def handle_call(:mailboxes, _from, state) do
    {:reply, state.mailboxes, state}
  end

  def handle_call(:message, _from, state) do
    {:reply, state.message, state}
  end

  def handle_call(:list_mode, _from, state) do
    {:reply, state.list_mode, state}
  end

  def handle_call(:fetch_mode, _from, state) do
    {:reply, state.fetch_mode, state}
  end

  def handle_call(:include_envelope, _from, state) do
    {:reply, state.include_envelope, state}
  end

  def handle_call(:include_header, _from, state) do
    {:reply, state.include_header, state}
  end

  def handle_call(:search_unseen, _from, state) do
    values = if state.seen, do: [], else: [1]
    {:reply, values, state}
  end

  def handle_call(:mark_seen, _from, state) do
    {:reply, :ok, %{state | seen: true}}
  end

  @impl GenServer
  def handle_info({:connection_started, pid}, state) do
    {:noreply, %{state | connections: MapSet.put(state.connections, pid)}}
  end

  def handle_info({:connection_closed, pid}, state) do
    {:noreply, %{state | connections: MapSet.delete(state.connections, pid)}}
  end

  def handle_info({:command, command, raw}, state) do
    if is_pid(state.owner), do: send(state.owner, {:imap_fake_command, self(), command, raw})
    {:noreply, %{state | command_log: [command | state.command_log]}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = Process.exit(state.acceptor, :normal)

    Enum.each(state.connections, fn pid -> Process.exit(pid, :normal) end)
    :ok
  end

  defp accept_loop(listen_socket, server) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        pid = spawn_link(fn -> connection_entry(server) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket_ready, socket})
        send(server, {:connection_started, pid})
        accept_loop(listen_socket, server)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen_socket, server)
    end
  end

  defp connection_entry(server) do
    receive do
      {:socket_ready, socket} ->
        :ok = :gen_tcp.send(socket, "* OK [CAPABILITY IMAP4rev1 IDLE] ZAQ Fake IMAP\r\n")
        connection_loop(%{server: server, socket: socket, idle_tag: nil, idle_notified: false})
    end
  end

  defp connection_loop(state) do
    receive do
      {:notify_exists, count} ->
        _ = :gen_tcp.send(state.socket, "* #{count} EXISTS\r\n")

        state =
          if state.idle_tag do
            %{state | idle_notified: true}
          else
            state
          end

        connection_loop(state)
    after
      10 ->
        case :gen_tcp.recv(state.socket, 0, 10) do
          {:ok, data} ->
            new_state = handle_client_line(String.trim_trailing(data, "\r\n"), state)

            case new_state do
              :stop ->
                send(state.server, {:connection_closed, self()})
                :ok

              _ ->
                connection_loop(new_state)
            end

          {:error, :timeout} ->
            connection_loop(state)

          {:error, :closed} ->
            send(state.server, {:connection_closed, self()})
            :ok
        end
    end
  end

  defp handle_client_line("DONE", %{idle_tag: nil} = state), do: state

  defp handle_client_line("DONE", %{socket: socket, idle_tag: tag, idle_notified: true} = state) do
    _ = :gen_tcp.send(socket, "#{tag} OK IDLE terminated\r\n")
    %{state | idle_tag: nil, idle_notified: false}
  end

  defp handle_client_line("DONE", state) do
    %{state | idle_tag: nil, idle_notified: false}
  end

  defp handle_client_line(line, state) do
    case String.split(line, " ", parts: 3) do
      [tag, command] ->
        dispatch_command(tag, command, "", line, state)

      [tag, command, rest] ->
        dispatch_command(tag, command, rest, line, state)

      _ ->
        state
    end
  end

  defp dispatch_command(tag, command, rest, raw, state) do
    command = String.upcase(command)
    notify_command(state.server, command, raw)
    run_command(command, tag, rest, state)
  end

  defp run_command("LOGIN", tag, _rest, state) do
    _ = :gen_tcp.send(state.socket, "#{tag} OK LOGIN completed\r\n")
    state
  end

  defp run_command("SELECT", tag, rest, state) do
    _ = :gen_tcp.send(state.socket, "* FLAGS (\\Seen)\r\n")
    _ = :gen_tcp.send(state.socket, "* 1 EXISTS\r\n")
    _ = :gen_tcp.send(state.socket, "* 1 RECENT\r\n")
    _ = :gen_tcp.send(state.socket, "* OK [UNSEEN 1] Message 1 is first unseen\r\n")

    _ =
      :gen_tcp.send(state.socket, "#{tag} OK [READ-WRITE] SELECT #{normalize_mailbox(rest)}\r\n")

    state
  end

  defp run_command("LIST", tag, _rest, state) do
    list_mailboxes(tag, state)
    state
  end

  defp run_command("SEARCH", tag, _rest, state) do
    send_search_response(state)
    _ = :gen_tcp.send(state.socket, "#{tag} OK SEARCH completed\r\n")
    state
  end

  defp run_command("FETCH", tag, _rest, state) do
    send_fetch_response(tag, state)
    state
  end

  defp run_command("STORE", tag, _rest, state) do
    _ = GenServer.call(state.server, :mark_seen)
    _ = :gen_tcp.send(state.socket, "* 1 FETCH (FLAGS (\\Seen))\r\n")
    _ = :gen_tcp.send(state.socket, "#{tag} OK STORE completed\r\n")
    state
  end

  defp run_command("IDLE", tag, _rest, state) do
    _ = :gen_tcp.send(state.socket, "+ idling\r\n")
    %{state | idle_tag: tag, idle_notified: false}
  end

  defp run_command("LOGOUT", tag, _rest, state) do
    _ = :gen_tcp.send(state.socket, "* BYE Logging out\r\n")
    _ = :gen_tcp.send(state.socket, "#{tag} OK LOGOUT completed\r\n")
    state
  end

  defp run_command(command, tag, _rest, state) do
    _ = :gen_tcp.send(state.socket, "#{tag} OK #{command} completed\r\n")
    state
  end

  defp list_mailboxes(tag, state) do
    case GenServer.call(state.server, :list_mode) do
      :bad ->
        _ = :gen_tcp.send(state.socket, "#{tag} BAD LIST failed\r\n")

      _ ->
        Enum.each(GenServer.call(state.server, :mailboxes), fn mailbox ->
          _ = :gen_tcp.send(state.socket, "* LIST (\\HasNoChildren) \"/\" \"#{mailbox}\"\r\n")
        end)

        _ = :gen_tcp.send(state.socket, "#{tag} OK LIST completed\r\n")
    end
  end

  defp send_search_response(state) do
    case GenServer.call(state.server, :search_unseen) do
      [] -> _ = :gen_tcp.send(state.socket, "* SEARCH\r\n")
      numbers -> _ = :gen_tcp.send(state.socket, "* SEARCH #{Enum.join(numbers, " ")}\r\n")
    end
  end

  defp send_fetch_response(tag, state) do
    case GenServer.call(state.server, :fetch_mode) do
      :broken ->
        _ = :gen_tcp.send(state.socket, "* 1 FETCH (\r\n")
        _ = :gen_tcp.send(state.socket, "#{tag} OK FETCH completed\r\n")

      _ ->
        message = GenServer.call(state.server, :message)
        include_envelope = GenServer.call(state.server, :include_envelope)
        include_header = GenServer.call(state.server, :include_header)

        _ =
          :gen_tcp.send(
            state.socket,
            fetch_response(message, include_envelope, include_header)
          )

        _ = :gen_tcp.send(state.socket, "#{tag} OK FETCH completed\r\n")
    end
  end

  defp notify_command(server, command, raw) do
    atom = Map.get(@command_atoms, command, :other)
    send(server, {:command, atom, raw})
  end

  defp fetch_response(message, include_envelope, include_header) do
    uid = Map.fetch!(message, :uid)
    subject = escape(Map.fetch!(message, :subject))
    from_name = escape(Map.fetch!(message, :from_name))
    from_mailbox = escape(Map.fetch!(message, :from_mailbox))
    from_host = escape(Map.fetch!(message, :from_host))
    message_id = escape(Map.fetch!(message, :message_id))
    in_reply_to = escape(Map.fetch!(message, :in_reply_to))
    references = escape("References: #{Map.fetch!(message, :references)}")
    rfc822 = escape(Map.fetch!(message, :rfc822))

    parts = ["UID #{uid}"]

    parts =
      if include_envelope do
        [
          ~s|ENVELOPE ("Mon, 07 Apr 2026 10:00:00 +0000" "#{subject}" (("#{from_name}" NIL "#{from_mailbox}" "#{from_host}")) NIL NIL NIL NIL NIL "#{in_reply_to}" "#{message_id}")|
          | parts
        ]
      else
        parts
      end

    parts = ["RFC822 \"#{rfc822}\"" | parts]

    parts =
      if include_header do
        ["BODY.PEEK[HEADER] \"#{references}\"" | parts]
      else
        parts
      end

    "* 1 FETCH (#{Enum.reverse(parts) |> Enum.join(" ")})\r\n"
  end

  defp normalize_mailbox(rest) do
    rest
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
