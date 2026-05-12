defmodule Zaq.Workflows.Examples.EmailReplyWorkflowRunic do
  @moduledoc """
  JidoRunic variant of the email reply workflow.

  Actions live in `Zaq.Agent.Tools.Email.*` for reuse across workflows.

  DAG shape:

                    fetch
                      │
           ┌──────────┴──────────┐
      (emails_found)        (no_emails)
           │                    │
         draft         notify_empty_mailbox
           │
      ensure_person
           │
        send_reply

  To start a run:

      Zaq.Workflows.Examples.EmailReplyWorkflowRunic.init()
      Zaq.Workflows.Examples.EmailReplyWorkflowRunic.init("runictest")
  """

  alias Jido.Runic.ActionNode
  alias Runic.Workflow

  require Runic

  alias Zaq.Agent.Tools.Email.{
    DraftReply,
    EnsurePerson,
    FetchEmails,
    NotifyEmptyMailbox,
    SendReply
  }

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Workflows.Conditions.{EmailsFound, NoEmails}

  @notify_address "jad.tarabay2@gmail.com"

  @doc """
  Starts the email reply agent and triggers one run immediately.

      iex> Zaq.Workflows.Examples.EmailReplyWorkflowRunic.init()
      iex> Zaq.Workflows.Examples.EmailReplyWorkflowRunic.init("runictest")
  """
  def init(mailbox \\ nil) do
    Jido.start()

    channel_config = ChannelConfig.get_by_provider("email:imap")
    unless channel_config, do: raise("No enabled email:imap channel config found in the database")

    imap_config = ImapConfigHelpers.normalize_bridge_config(channel_config)

    resolved_mailbox =
      mailbox ||
        channel_config.settings
        |> Map.get("imap", %{})
        |> Map.get("selected_mailboxes", ["INBOX"])
        |> List.first("INBOX")

    {:ok, pid} =
      Jido.AgentServer.start(
        jido: Jido.Default,
        agent: __MODULE__.Agent,
        initial_state: %{imap_config: imap_config}
      )

    {:ok, signal} =
      Jido.Signal.new("runic.feed", %{
        data: %{
          imap_config: imap_config,
          mailbox: resolved_mailbox
        }
      })

    Jido.AgentServer.call(pid, signal)

    {:ok, pid}
  end

  @doc "Builds and returns the Runic DAG for this workflow."
  def dag do
    fetch = ActionNode.new(FetchEmails, %{}, name: :fetch)

    notify_empty_mailbox =
      ActionNode.new(NotifyEmptyMailbox, %{notify_address: @notify_address},
        name: :notify_empty_mailbox
      )

    draft = ActionNode.new(DraftReply, %{}, name: :draft)
    ensure_person = ActionNode.new(EnsurePerson, %{}, name: :ensure_person)
    send_reply = ActionNode.new(SendReply, %{}, name: :send_reply)

    emails_found = Runic.condition(&EmailsFound.call/1, name: :emails_found)
    no_emails = Runic.condition(&NoEmails.call/1, name: :no_emails)

    Workflow.new(:email_reply)
    |> Workflow.add(fetch)
    |> Workflow.add(emails_found, to: :fetch)
    |> Workflow.add(no_emails, to: :fetch)
    |> Workflow.add(notify_empty_mailbox, to: :no_emails, validate: :off)
    |> Workflow.add(draft, to: :emails_found, validate: :off)
    |> Workflow.add(ensure_person, to: :draft)
    |> Workflow.add(send_reply, to: :ensure_person)
  end
end

# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

defmodule Zaq.Workflows.Examples.EmailReplyWorkflowRunic.Agent do
  @moduledoc """
  Jido agent that runs the email reply DAG via Jido.Runic.Strategy.
  The cron fires every 30 minutes automatically once started.
  """

  alias Zaq.Workflows.Examples.EmailReplyWorkflowRunic

  use Jido.Agent,
    name: "email_reply_runic",
    strategy: {Jido.Runic.Strategy, workflow_fn: &EmailReplyWorkflowRunic.dag/0},
    schema: [
      imap_config: [type: :any, required: true],
      mailbox: [type: :string, default: "INBOX"]
    ],
    schedules: [
      {"*/30 * * * *", "runic.feed", job_id: :email_check}
    ]
end
