defmodule Zaq.Channels.EmailBridge.ImapClient do
  @moduledoc "Runtime-configurable IMAP client boundary."

  @callback connect(String.t(), String.t(), String.t(), keyword()) :: term()
  @callback select(pid(), String.t()) :: term()
  @callback list(pid()) :: term()
  @callback status(pid(), String.t(), list()) :: term()
  @callback state(pid()) :: term()
  @callback search(pid(), String.t(), list(), (term() -> any())) :: term()
  @callback fetch(pid(), term(), list(), nil, keyword()) :: term()
  @callback mode(pid(), atom()) :: term()
  @callback add_flags(pid(), term(), list()) :: term()
  @callback idle(pid(), pid(), atom(), keyword()) :: term()
  @callback cancel_idle(pid()) :: term()
  @callback logout(pid()) :: term()

  def connect(server, username, password, opts),
    do: Mailroom.IMAP.connect(server, username, password, opts)

  def select(client, mailbox), do: Mailroom.IMAP.select(client, mailbox)
  def list(client), do: Mailroom.IMAP.list(client)
  def status(client, mailbox, items), do: Mailroom.IMAP.status(client, mailbox, items)
  def state(client), do: Mailroom.IMAP.state(client)

  def search(client, query, items, callback),
    do: Mailroom.IMAP.search(client, query, items, callback)

  def fetch(client, sequence, items, callback, opts),
    do: Mailroom.IMAP.fetch(client, sequence, items, callback, opts)

  def mode(client, mode), do: Mailroom.IMAP.mode(client, mode)
  def add_flags(client, sequence, flags), do: Mailroom.IMAP.add_flags(client, sequence, flags)

  def idle(client, callback_pid, message, opts),
    do: Mailroom.IMAP.idle(client, callback_pid, message, opts)

  def cancel_idle(client), do: Mailroom.IMAP.cancel_idle(client)
  def logout(client), do: Mailroom.IMAP.logout(client)
end
