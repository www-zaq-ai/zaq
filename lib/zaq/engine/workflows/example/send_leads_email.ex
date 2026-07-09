defmodule Zaq.Engine.Workflows.UseCases.SendLeadsEmail do
  @moduledoc """
  Workflow use case: send a personalised email to each lead dispatched by
  `IdentifyLeadsFromGoogleSheet` / `GenerateCompanyContext`.

  Triggered by: `craft_email` event (dispatched as a machine/actorless `Zaq.Event`
  to :engine, so the run carries `skip_permissions: true`). The event payload
  (= the Google Sheet row) is the initial input to the run.

  ## The `start` namespace (trigger payload contract)

  The trigger payload is kept for the whole run in the persistent `start`
  namespace — a virtual origin node whose "output" is the row that triggered the
  run. Any edge `mapping` (or `{{start.<field>}}` placeholder) can read a field
  from it via a `start.<field>` dotted path, exactly as it reads a real upstream
  node's output (e.g. `draft_email.output`). This decouples downstream steps from
  any single node having to echo the row: `start.sequence`, `start.row_index`, and
  `start.company context content` below come straight from the trigger.

  DAG (linear):
    ensure_person
      → build_history            ← History — the ensured lead's own conversation,
                                    matched by person_id AND the email topic
                                    (query = start.email topic, search_in: title)
      → check_last_message_date  ← Workflow.Condition — recency gate; proceeds only
                                    when the last message is nil or older than 3 days
                                    (on_fail: continue → routes on `passed`)
      → build_agent_context      ← Workflow.Concat (list mode) — seeds an agent
                                    message array: a system turn + prior history
      → draft_email              ← RunAgent(agent_id) — writes the email BODY,
                                    seeded with `context` from build_agent_context.list
      → review_email             (human-in-the-loop)
      → send_email               ← NotifyPerson — subject = start.email topic + agent body
      → update_history           ← PersistMessageHistory — records the sent message
      → increment_email_state    ← Workflow.Increment — bumps the sequence counter
      → build_range              ← Workflow.Concat — concatenates the A1 range string
      → build_values             ← Workflow.Concat — wraps the value as a [[value]] matrix
      → update_sheet_row         ← UpdateSheetValues range mode (range/values)

  ## Recency gate (`check_last_message_date`)

  The `Condition` node runs in `on_fail: "continue"` (routing) mode and evaluates
  `total.last_message_date >= today - 3d` (datetime). That is `true` only for a
  real, recent date; both `nil` (no history) and "older than 3 days" coerce to
  `false`. The outgoing edge fires on `passed == false`, so the run proceeds for
  the nil/stale cases and stops (no outgoing edge) when the last message is recent.

  Row shape expected from the trigger (each field readable as `start.<field>`):
    %{
      "email"                   => "lead@example.com",
      "name"                    => "John Doe",
      "company"                 => "Acme Corp",
      "language"                => "french" | "english", # → start.language (email language)
      "company context content" => "…company summary…",  # → start.company context content
      "email topic"             => "…subject…",  # → start.email topic (subject/history query/topic)
      "sequence"                => 2,        # current sequence counter  → start.sequence
      "row_index"               => 5         # 1-based sheet row number   → start.row_index
    }

  ## Usage

      {:ok, workflow} = SendLeadsEmail.create()
  """

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.Helper

  @ensure_person_module "Zaq.Agent.Tools.People.EnsurePerson"
  @build_history_module "Zaq.Agent.Tools.Accounts.History"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"
  @concat_module "Zaq.Agent.Tools.Workflow.Concat"
  @draft_email_module "Zaq.Agent.Tools.Workflow.RunAgent"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @send_email_module "Zaq.Agent.Tools.People.NotifyPerson"
  @persist_history_module "Zaq.Agent.Tools.Conversations.PersistMessageHistory"
  @increment_module "Zaq.Agent.Tools.Workflow.Increment"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  @sheet_id "1sYIdoX6KWDCyapowvfrfebE71gUWQo3A5S_GqpXXarI"
  @event_name "craft_email"

  # Fallback email subject. The real per-lead subject comes from the trigger row as
  # `start.email topic`, delivered via edge mappings to the history lookup query
  # (search_in: title), the sent email subject, and the persisted conversation topic —
  # so every message for a lead lands in the same thread. This literal is only used if
  # the row carries no `email topic`.
  @email_subject "Your team's AI-powered company brain"

  @draft_email_prompt ~s|Write an outreach email for {{name}} at {{company}}. Write the ENTIRE email body in {{language}} (the lead's language). Use the company context and the list of relevant value added ZAQ can have for this company to select the most relevent one and entice the person to book a meeting with me (Julien at ZAQ). Also check the previous messages sent to not repeat yourself and instead use a different angle that can convince the person of the added value ZAQ can have for them. Write only the email body (no subject line), ending with the sign-off "Julien, ZAQ".|

  @doc """
  Creates the workflow and wires it to the `craft_email` trigger.
  Returns `{:ok, workflow}`.
  """
  @spec create(keyword()) :: {:ok, Workflows.Workflow.t()} | {:error, term()}
  def create(opts \\ []) do
    Helper.create_workflow_with_trigger(build(opts), %{event_name: @event_name})
  end

  @doc """
  Returns the workflow params map. Pass opts to override defaults:
  - `:sheet_id` — Google Spreadsheet ID (default: hardcoded lead sheet)
  - `:provider` — datasource provider key (default: "google_drive")
  - `:email_state_column` — column letter for email_state (default: "J")
  - `:agent_id` — ID of the ZAQ agent used for drafting (default: 1)
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    sheet_id = Keyword.get(opts, :sheet_id, @sheet_id)
    provider = Keyword.get(opts, :provider, "google_drive")
    email_state_column = Keyword.get(opts, :email_state_column, "J")
    agent_id = Keyword.get(opts, :agent_id, 1)

    %{
      name: "Send Leads Email",
      status: "active",
      nodes: [
        %{
          name: "ensure_person",
          type: "action",
          module: @ensure_person_module,
          params: %{"platform" => "email"},
          index: 0
        },
        %{
          name: "build_history",
          type: "action",
          module: @build_history_module,
          # The email topic is the history query: search_in: title matches this lead's
          # conversation (all its messages share the same subject/title). The per-lead
          # value is delivered by the incoming edge (`start.email topic`); this static
          # `query` is only a fallback.
          params: %{"query" => @email_subject, "search_in" => "title"},
          index: 1
        },
        %{
          name: "check_last_message_date",
          type: "action",
          module: @condition_module,
          # `input` is a dotted reference into the run cascade. The `Condition` tool
          # resolves a string `input` against the cascade (node params themselves are
          # NOT engine-resolved), so it reads the actual `build_history.metadata` map.
          # It must stay a node param (not only an edge mapping): the node needs its
          # own `input` to be scheduled/fire — delivering it solely via an edge left
          # the node never executing.
          params: %{
            "input" => "build_history.metadata",
            "on_fail" => "continue",
            "conditions" => [
              %{
                "key" => "total.last_message_date",
                "type" => "datetime",
                "op" => "gte",
                "value" => %{"from" => "now", "minutes" => -5}
              }
            ]
          },
          index: 2
        },
        %{
          name: "build_agent_context",
          type: "action",
          module: @concat_module,
          params: %{
            "parts" => [
              # The company context document (company summary + the "How ZAQ can help"
              # value-add list) dispatched by GenerateCompanyContext — the agent's
              # primary source for the email. Seeded as a `user` turn so the model
              # reads it as provided grounding material, not something it "said".
              [%{"role" => "assistant", "content" => "{{start.company context content}}"}],
              "{{build_history.messages}}"
            ]
          },
          index: 3
        },
        %{
          name: "draft_email",
          type: "action",
          module: @draft_email_module,
          params: %{"agent_id" => agent_id, "input" => @draft_email_prompt},
          index: 4
        },
        %{
          name: "review_email",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{"message" => "Review and approve the drafted lead email before sending."},
          index: 5
        },
        %{
          name: "send_email",
          type: "action",
          module: @send_email_module,
          # `subject` (start.email topic) and `message` (draft_email.output, the agent's
          # body) are supplied by the incoming edge. This static subject is only a fallback.
          params: %{"subject" => @email_subject},
          index: 6
        },
        %{
          name: "update_history",
          type: "action",
          module: @persist_history_module,
          # `topic` (start.email topic) is supplied by the incoming edge, so every message
          # for this lead lands in the same thread (email:imap keys by topic/subject).
          params: %{},
          index: 7
        },
        %{
          name: "increment_email_state",
          type: "action",
          module: @increment_module,
          params: %{},
          index: 8
        },
        %{
          name: "build_range",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["Sheet1!{{column}}{{row}}"], "column" => email_state_column},
          index: 9
        },
        %{
          name: "build_values",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["{{value}}"], "as_matrix" => true},
          index: 10
        },
        %{
          name: "update_sheet_row",
          type: "action",
          module: @update_sheet_module,
          params: %{
            "spreadsheet_id" => sheet_id,
            "provider" => provider,
            "value_input_option" => "USER_ENTERED"
          },
          index: 11
        }
      ],
      edges: [
        # Only proceed once a person exists. Scope the history lookup to the lead just
        # ensured: on this machine run (skip_permissions) `History` honors the `person_id`
        # param, and `query` (the email topic from `start.email topic`) narrows to that
        # lead's own conversation — so the recency gate reads the right thread.
        %{
          from: "ensure_person",
          to: "build_history",
          condition: %{"field" => "person", "op" => "not_empty"},
          mapping: %{
            "person_id" => "ensure_person.person.id",
            "query" => "start.email topic"
          }
        },
        %{
          from: "build_history",
          to: "check_last_message_date",
          mapping: %{"row" => "ensure_person.row"}
        },
        %{
          from: "check_last_message_date",
          to: "build_agent_context",
          condition: %{"field" => "passed", "op" => "eq", "value" => false}
        },
        %{
          from: "build_agent_context",
          to: "draft_email",
          # `context` seeds the agent's message history (cascade-aware). `name`/`company`
          # are flattened onto the node so the `{{name}}`/`{{company}}` placeholders in
          # the prompt resolve — RunAgent's input substitution only sees flat `\w+` vars.
          mapping: %{
            "context" => "build_agent_context.list",
            "name" => "start.input.name",
            "company" => "start.company official name",
            "language" => "start.language"
          }
        },
        %{
          from: "draft_email",
          to: "review_email",
          condition: %{"field" => "output", "op" => "not_empty"}
        },
        # On approval, send with the email topic as subject (start.email topic) and the
        # agent's drafted body (draft_email.output).
        %{
          from: "review_email",
          to: "send_email",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{
            "subject" => "start.email topic",
            "message" => "draft_email.output",
            "person" => "ensure_person.person"
          }
        },
        # Persist under the email topic (start.email topic) as the conversation `topic`,
        # so every message for this lead lands in the same thread (email:imap keys by
        # topic/subject).
        %{
          from: "send_email",
          to: "update_history",
          condition: %{"field" => "notified", "op" => "eq", "value" => true},
          mapping: %{"person" => "ensure_person.person", "topic" => "start.email topic"}
        },
        %{
          from: "update_history",
          to: "increment_email_state",
          condition: %{"field" => "persisted", "op" => "eq", "value" => true},
          mapping: %{"value" => "start.sequence"}
        },
        %{
          from: "increment_email_state",
          to: "build_range",
          mapping: %{"row" => "start.row_index"}
        },
        %{
          from: "build_range",
          to: "build_values",
          mapping: %{"value" => "increment_email_state.value"}
        },
        %{
          from: "build_values",
          to: "update_sheet_row",
          mapping: %{"range" => "build_range.result", "values" => "build_values.matrix"}
        }
      ]
    }
  end
end
