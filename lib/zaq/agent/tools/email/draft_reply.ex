defmodule Zaq.Agent.Tools.Email.DraftReply do
  @moduledoc """
  Receives a list of fetched emails, calls a named ZAQ agent to draft a reply
  for each, and returns the drafts.

  The agent name is resolved at runtime from the `:agent_name` param
  (default: "MailResponder"). An empty emails list short-circuits to `%{drafts: []}`.
  """

  # THIS JIDO ACTION IS FOR TESTING PURPOSES
  # IT WILL GET REMOVED IN THE FUTURE
  use Jido.Action,
    name: "draft_reply",
    schema: [
      emails: [type: :any, required: true],
      agent_name: [type: :string, default: "MailResponder"]
    ],
    output_schema: [
      drafts: [type: {:list, :map}, required: true]
    ]

  require Logger

  alias Zaq.Agent.{ConfiguredAgent, Executor}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo
  import Ecto.Query

  use Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_failure(error, _context) do
    Logger.warning("[DraftReply] step failed: #{inspect(error)}")
    :ok
  end

  @impl true
  def run(%{emails: emails} = params, _context) do
    agent_name = Map.get(params, :agent_name, "MailResponder")
    agent_id = resolve_agent_id!(agent_name)

    drafts =
      Enum.map(emails, fn raw_email ->
        from = raw_email["from"] || %{}
        from_address = from["address"] || from[:address]
        from_name = from["name"] || from[:name]
        subject = raw_email["subject"]
        body = raw_email["body_text"] || ""

        incoming = %Incoming{
          content: build_prompt(from_name || from_address, subject, body),
          channel_id: from_address,
          author_id: from_address,
          author_name: from_name,
          provider: :"email:imap",
          metadata: %{"subject" => subject}
        }

        outgoing = Executor.run(incoming, agent_id: agent_id)

        %{
          to_address: from_address,
          to_name: from_name,
          subject: reply_subject(subject),
          draft: outgoing.body,
          message_id: raw_email["message_id"]
        }
      end)

    logs = [
      %{
        level: "info",
        message: "Drafted #{length(drafts)} reply(s)",
        metadata: %{count: length(drafts)}
      }
    ]

    {:ok, %{drafts: drafts}, logs: logs}
  end

  defp resolve_agent_id!(agent_name) do
    case Repo.one(
           from a in ConfiguredAgent,
             where: a.name == ^agent_name and a.active == true,
             select: a.id
         ) do
      nil -> raise "ZAQ agent '#{agent_name}' not found or inactive"
      id -> id
    end
  end

  defp build_prompt(sender, subject, body) do
    """
    You received an email from #{sender}.
    Subject: #{subject || "(no subject)"}
    ---
    #{body}
    ---
    Draft a professional, concise reply. Write only the email body — do not include a subject line or any "Subject:" prefix.
    """
  end

  defp reply_subject(nil), do: "Re: (no subject)"
  defp reply_subject("Re: " <> _ = s), do: s
  defp reply_subject(s), do: "Re: #{s}"
end
