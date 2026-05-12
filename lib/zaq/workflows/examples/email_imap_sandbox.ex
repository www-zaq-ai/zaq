defmodule Zaq.Workflows.Examples.EmailImapSandbox do
  @moduledoc """
  IEx sandbox for exploring IMAP mailboxes.

  Mailboxes are read from the configured selected_mailboxes in the database.
  All functions accept an optional `limit:` keyword (default: 20) so large
  inboxes don't hang the shell.

  Usage:

      alias Zaq.Workflows.Examples.EmailImapSandbox, as: Sandbox

      Sandbox.selected_mailboxes()
      Sandbox.subject_lines()                    # selected mailboxes, limit 20
      Sandbox.subject_lines(limit: 5)
      Sandbox.subject_lines("INBOX")             # specific mailbox, limit 20
      Sandbox.subject_lines("INBOX", limit: 50)
      Sandbox.list_emails()
      Sandbox.list_emails("INBOX", limit: 10)
      Sandbox.show_email(0)
  """

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.{ImapAdapter, ImapConfigHelpers}

  @default_limit 20

  @doc "List all mailboxes available on the IMAP account."
  def list_mailboxes do
    {config, _} = load()
    ImapAdapter.list_mailboxes(config)
  end

  @doc "Returns the mailboxes the user selected in the BO config."
  def selected_mailboxes do
    {_config, channel_config} = load()
    mailboxes_from(channel_config)
  end

  @doc "Fetch unseen emails across all selected mailboxes. Accepts `limit:` keyword."
  def list_emails(opts \\ []) when is_list(opts) do
    {config, channel_config} = load()
    limit = Keyword.get(opts, :limit, @default_limit)

    for mailbox <- mailboxes_from(channel_config), reduce: [] do
      acc ->
        case fetch_from(config, mailbox, limit) do
          {:ok, emails} ->
            acc ++ emails

          {:error, reason} ->
            IO.puts("  [#{mailbox}] error: #{inspect(reason)}")
            acc
        end
    end
  end

  @doc "Fetch unseen emails from a specific mailbox. Accepts `limit:` keyword."
  def list_emails(mailbox, opts) when is_binary(mailbox) and is_list(opts) do
    {config, _channel_config} = load()
    limit = Keyword.get(opts, :limit, @default_limit)

    case fetch_from(config, mailbox, limit) do
      {:ok, emails} -> emails
      {:error, reason} -> raise "Failed to fetch from #{mailbox}: #{inspect(reason)}"
    end
  end

  @doc "Print subject lines across selected mailboxes. Accepts `limit:` keyword."
  def subject_lines(opts \\ []) when is_list(opts) do
    opts |> list_emails() |> print_subjects()
  end

  @doc "Print subject lines from a specific mailbox. Accepts `limit:` keyword."
  def subject_lines(mailbox, opts) when is_binary(mailbox) and is_list(opts) do
    mailbox |> list_emails(opts) |> print_subjects()
  end

  @doc "Print full details of one email by index."
  def show_email(index, opts \\ []) when is_list(opts) do
    emails = list_emails(opts)

    case Enum.at(emails, index) do
      nil ->
        IO.puts("No email at index #{index} (fetched #{length(emails)} emails)")

      fields ->
        envelope = fields[:envelope]

        IO.puts("""
        Mailbox: #{fields[:_mailbox]}
        From:    #{sender_address(fields)}
        Subject: #{envelope && envelope.subject}
        Date:    #{envelope && envelope.date_string}
        Body:
        #{fields[:rfc822] || "(empty)"}
        """)
    end

    :ok
  end

  # -- Private -----------------------------------------------------------------

  defp load do
    channel_config = ChannelConfig.get_by_provider("email:imap")
    unless channel_config, do: raise("No enabled email:imap channel config found")
    config = ImapConfigHelpers.normalize_bridge_config(channel_config)
    {config, channel_config}
  end

  defp mailboxes_from(channel_config) do
    channel_config.settings
    |> Map.get("imap", %{})
    |> Map.get("selected_mailboxes", ["INBOX"])
    |> case do
      [] -> ["INBOX"]
      list -> list
    end
  end

  defp fetch_from(config, mailbox, limit) do
    task =
      Task.async(fn ->
        with {:ok, client} <- ImapAdapter.connect(config, mailbox) do
          total = Mailroom.IMAP.email_count(client)
          first = max(1, total - limit + 1)
          range = first..total

          {:ok, raw} = Mailroom.IMAP.fetch(client, range, [:uid, :envelope, :rfc822])
          results = tag_mailbox(raw, mailbox)

          ImapAdapter.disconnect(client)
          {:ok, results}
        end
      end)

    Task.await(task, 30_000)
  end

  defp tag_mailbox(raw, mailbox) do
    Enum.map(raw, fn {_seq, fields} -> Map.put(fields, :_mailbox, mailbox) end)
  end

  defp print_subjects(emails) do
    emails
    |> Enum.with_index()
    |> Enum.each(fn {fields, i} ->
      envelope = fields[:envelope]
      subject = (envelope && envelope.subject) || "(no subject)"
      from = fields |> sender_address() || "(unknown)"
      mailbox = fields[:_mailbox] || ""
      IO.puts("  [#{i}] [#{mailbox}] #{subject}  <#{from}>")
    end)

    :ok
  end

  defp sender_address(fields) do
    with %{from: [first | _]} <- fields[:envelope],
         email when is_binary(email) <- first.email do
      email
    else
      _ -> nil
    end
  end
end
