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
      → build_subject            ← Workflow.Concat — per-lead CONVERSATION NAME
                                    ("…company brain - <Company>"). Drives the history
                                    query AND the persisted conversation name/routing —
                                    NOT the email subject (the agent writes that).
      → build_history            ← History — the ensured lead's own conversation,
                                    matched by person_id AND the conversation name (query)
      → check_last_message_date  ← Workflow.Condition — recency gate; proceeds only
                                    when the last message is nil or older than 3 days
                                    (on_fail: continue → routes on `passed`)
      → build_agent_context      ← Workflow.Concat (list mode) — seeds an agent
                                    message array: a system turn + prior history
      → draft_email              ← RunAgent(agent_id) — subject on line 1 + body,
                                    seeded with `context` from build_agent_context.list
      → review_email             (human-in-the-loop)
      → split_draft              ← Workflow.Split — split the draft on the first newline
                                    into `before` (subject) + `after` (body)
      → send_email               ← NotifyPerson (agent's own subject + body)
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
  @split_module "Zaq.Agent.Tools.Workflow.Split"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @send_email_module "Zaq.Agent.Tools.People.NotifyPerson"
  @persist_history_module "Zaq.Agent.Tools.Conversations.PersistMessageHistory"
  @increment_module "Zaq.Agent.Tools.Workflow.Increment"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  @event_name "craft_email"

  @draft_email_prompt ~s|Write an outreach email for {{name}} at {{company}}. Write the ENTIRE email — both the subject and the body — in {{language}} (the lead's language). Use the company context and the list of relevant value added ZAQ can have for this company to select the most relevent one and entice the person to book a meeting with me (Julien at ZAQ). Also check the previous messages sent to not repeat yourself and instead use a different angle that can convince the person of the added value ZAQ can have for them. FORMAT: put the email SUBJECT on the FIRST line by itself — a short, specific line, and do NOT prefix it with "Subject:". Then the email body on the following lines, ending with the sign-off "Julien, ZAQ".|

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
        # Build the per-lead CONVERSATION NAME up front (NOT the email subject — the
        # agent writes that). It drives BOTH the history lookup (find this lead's own
        # conversation by its unique title) and, later, the persisted conversation's
        # name/routing (via `topic` on update_history). Email conversations are keyed
        # by topic/subject (email:imap), so a per-company name keeps each lead's thread
        # separate. The actual email subject is the agent's own (see split_draft).
        %{
          name: "build_subject",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["Your team's AI-powered company brain - {{company}}"]},
          index: 1
        },
        %{
          name: "build_history",
          type: "action",
          module: @build_history_module,
          # `query` is overridden per-lead by the incoming edge (build_subject.result);
          # this static value is only a fallback. search_in: title matches the
          # conversation whose title is the built subject.
          params: %{"query" => "Your team's AI-powered company brain", "search_in" => "title"},
          index: 2
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
                "value" => %{"from" => "today", "minutes" => -30}
              }
            ]
          },
          index: 3
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
              [%{"role" => "user", "content" => "{{start.company context content}}"}],
              "{{build_history.messages}}"
            ]
          },
          index: 4
        },
        %{
          name: "draft_email",
          type: "action",
          module: @draft_email_module,
          params: %{"agent_id" => agent_id, "input" => @draft_email_prompt},
          index: 5
        },
        %{
          name: "review_email",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{"message" => "Review and approve the drafted lead email before sending."},
          index: 6
        },
        # Split the agent's draft into subject + body. The agent writes the subject on
        # the first line and the body after, so splitting on the first newline yields
        # `before` (the email subject) and `after` (the body). This keeps the agent's
        # own subject on the email header instead of buried inside the body.
        %{
          name: "split_draft",
          type: "action",
          module: @split_module,
          params: %{"separator" => "\n"},
          index: 7
        },
        %{
          name: "send_email",
          type: "action",
          module: @send_email_module,
          # `subject` and `message` are supplied by the incoming edge (split_draft.before /
          # split_draft.after). The static subject is only a fallback.
          params: %{"subject" => "Your team's AI-powered company brain"},
          index: 8
        },
        %{
          name: "update_history",
          type: "action",
          module: @persist_history_module,
          params: %{},
          index: 9
        },
        %{
          name: "increment_email_state",
          type: "action",
          module: @increment_module,
          params: %{},
          index: 10
        },
        %{
          name: "build_range",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["Sheet1!{{column}}{{row}}"], "column" => email_state_column},
          index: 11
        },
        %{
          name: "build_values",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["{{value}}"], "as_matrix" => true},
          index: 12
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
          index: 13
        }
      ],
      edges: [
        # Only proceed once a person exists; build this lead's unique subject first.
        %{
          from: "ensure_person",
          to: "build_subject",
          condition: %{"field" => "person", "op" => "not_empty"},
          mapping: %{"company" => "start.company official name"}
        },
        # Scope the history lookup to the lead just ensured AND to this lead's unique
        # conversation title. On this machine run (skip_permissions) `History` honors
        # the `person_id` param, and `query` (the per-lead subject) narrows to that
        # lead's own conversation — so the recency gate reads the right thread.
        %{
          from: "build_subject",
          to: "build_history",
          mapping: %{
            "person_id" => "ensure_person.person.id",
            "query" => "build_subject.result"
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
        # On approval, split the draft into subject + body...
        %{
          from: "review_email",
          to: "split_draft",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{"text" => "draft_email.output"}
        },
        # ...then send with the agent's own subject (split_draft.before) and body
        # (split_draft.after).
        %{
          from: "split_draft",
          to: "send_email",
          mapping: %{
            "subject" => "split_draft.before",
            "message" => "split_draft.after",
            "person" => "ensure_person.person"
          }
        },
        # Persist under the per-lead conversation NAME (build_subject.result), not the
        # agent's email subject: `topic` is what PersistMessageHistory uses to name and
        # route the conversation (email:imap keys by topic before subject), so every
        # message for this lead lands in its own "…company brain - <Company>" thread.
        %{
          from: "send_email",
          to: "update_history",
          condition: %{"field" => "notified", "op" => "eq", "value" => true},
          mapping: %{"person" => "ensure_person.person", "topic" => "build_subject.result"}
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
