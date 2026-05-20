defmodule Zaq.Agent.Tools.Email.FetchEmails do
  @moduledoc """
  Connects to IMAP, fetches all unseen emails from a mailbox, and returns them.

  Returns `%{emails: [...], count: n}`. An empty list means no unseen messages.
  Resolves the IMAP config from the database via `ChannelConfig.get_by_provider/1`.
  """

  # THIS JIDO ACTION IS FOR TESTING PURPOSES
  # IT WILL GET REMOVED IN THE FUTURE
  use Jido.Action,
    name: "fetch_emails",
    schema: [
      imap_config: [type: :any, required: false],
      mailbox: [type: :string, default: "INBOX"]
    ],
    output_schema: [
      emails: [type: {:list, :map}, required: true],
      count: [type: :integer, required: true]
    ]

  require Logger

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.{ImapAdapter, ImapConfigHelpers}

  use Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_failure(error, _context) do
    Logger.warning("[FetchEmails] step failed: #{inspect(error)}")
    :ok
  end

  @impl true
  def run(params, _context) do
    mailbox = Map.get(params, :mailbox, "INBOX")

    imap_config =
      case Map.get(params, :imap_config) do
        nil ->
          case ChannelConfig.get_by_provider("email:imap") do
            nil -> raise "No enabled email:imap channel config found in the database"
            config -> ImapConfigHelpers.normalize_bridge_config(config)
          end

        provided ->
          provided
      end

    task =
      Task.async(fn ->
        with {:ok, client} <- ImapAdapter.connect(imap_config, mailbox) do
          emails = collect_unseen(client, mailbox)
          ImapAdapter.disconnect(client)
          {:ok, emails}
        end
      end)

    case Task.await(task, 30_000) do
      {:ok, emails} ->
        count = length(emails)

        logs = [
          %{
            level: "info",
            message: "Fetched #{count} unseen email(s) from #{mailbox}",
            metadata: %{mailbox: mailbox, count: count}
          }
        ]

        {:ok, %{emails: emails, count: count}, logs: logs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_unseen(client, mailbox) do
    {:ok, acc} = Agent.start_link(fn -> [] end)

    ImapAdapter.fetch_unseen(client, mailbox, fn email ->
      Agent.update(acc, fn list -> [email | list] end)
    end)

    emails = acc |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(acc)
    emails
  end
end
