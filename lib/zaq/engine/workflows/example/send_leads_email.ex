defmodule Zaq.Engine.Workflows.UseCases.SendLeadsEmail do
  @moduledoc """
  Workflow use case: send a personalised email to each lead dispatched by
  `IdentifyLeadsFromGoogleSheet`.

  Triggered by: `:lead_identified` event (dispatched as `Zaq.Event` to :engine).
  The event payload (= the Google Sheet row) is the initial input to the run.

  ## The `start` namespace (trigger payload contract)

  The trigger payload is kept for the whole run in the persistent `start`
  namespace — a virtual origin node whose "output" is the row that triggered the
  run. Any edge `mapping` can read a field from it via a `start.<field>` dotted
  path, exactly as it reads a real upstream node's output (e.g. `draft_email.output`).
  This decouples downstream steps from any single node having to echo the row:
  `start.sequence` and `start.row_index` below come straight from the trigger,
  not from `ensure_person`.

  DAG (linear):
    ensure_person
      → build_history
      → draft_email          ← RunAgent(agent_id) — body returned as `output`
      → review_email         (human-in-the-loop)
      → send_email
      → increment_email_state ← Workflow.Increment — bumps the sequence counter
      → build_range           ← Workflow.Concat — concatenates the A1 range string
      → build_values          ← Workflow.Concat — wraps the value as a [[value]] matrix
      → update_sheet_row      ← UpdateSheetValues range mode (range/values)

  Row shape expected from the trigger (each field readable as `start.<field>`):
    %{
      "email"        => "lead@example.com",
      "name"         => "John Doe",
      "company"      => "Acme Corp",
      "sequence"     => 2,        # current sequence counter  → start.sequence
      "row_index"    => 5,        # 1-based sheet row number   → start.row_index
      "position"     => "CTO",    # optional enrichment
      "industry"     => "SaaS",   # optional enrichment
      "size"         => "50-200", # optional enrichment
      "services"     => "..."     # optional enrichment
    }

  ## Usage

      {:ok, workflow} = SendLeadsEmail.create()
  """

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.Helper

  @ensure_person_module "Zaq.Agent.Tools.People.EnsurePerson"
  @build_history_module "Zaq.Agent.Tools.Accounts.History"
  @draft_email_module "Zaq.Agent.Tools.Workflow.RunAgent"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @send_email_module "Zaq.Agent.Tools.People.NotifyPerson"
  @increment_module "Zaq.Agent.Tools.Workflow.Increment"
  @build_range_module "Zaq.Agent.Tools.Workflow.Concat"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  @event_name "lead_identified"

  @doc """
  Creates the workflow and wires it to the `lead_identified` trigger.
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
  - `:email_state_column` — column letter for email_state (default: "I")
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
          params: %{},
          index: 1
        },
        %{
          name: "draft_email",
          type: "action",
          module: @draft_email_module,
          params: %{
            "agent_id" => agent_id,
            "input" =>
              "Draft outreach email for {{name}} ({{email}}) at {{company}}. Email sequence: {{sequence}}."
          },
          index: 2
        },
        %{
          name: "review_email",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{"message" => "Review and approve the drafted lead email before sending."},
          index: 3
        },
        %{
          name: "send_email",
          type: "action",
          module: @send_email_module,
          params: %{
            "subject" => "Your team's AI-powered company brain"
          },
          index: 4
        },
        %{
          name: "increment_email_state",
          type: "action",
          module: @increment_module,
          params: %{},
          index: 5
        },
        %{
          name: "build_range",
          type: "action",
          module: @build_range_module,
          params: %{
            "parts" => ["Sheet1!{{column}}{{row}}"],
            "column" => email_state_column
          },
          index: 6
        },
        %{
          name: "build_values",
          type: "action",
          module: @build_range_module,
          params: %{"parts" => ["{{value}}"], "as_matrix" => true},
          index: 7
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
          index: 8
        }
      ],
      edges: [
        %{
          from: "ensure_person",
          to: "build_history",
          condition: %{"field" => "person", "op" => "not_empty"},
          mapping: %{"person_id" => "ensure_person.person.id"}
        },
        %{from: "build_history", to: "draft_email", mapping: %{"row" => "ensure_person.row"}},
        %{
          from: "draft_email",
          to: "review_email",
          condition: %{"field" => "output", "op" => "not_empty"}
        },
        %{
          from: "review_email",
          to: "send_email",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{
            "message" => "draft_email.output",
            "person" => "ensure_person.person"
          }
        },
        %{
          from: "send_email",
          to: "increment_email_state",
          condition: %{"field" => "notified", "op" => "eq", "value" => true},
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
