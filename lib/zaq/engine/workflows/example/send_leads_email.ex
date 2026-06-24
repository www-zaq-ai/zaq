defmodule Zaq.Engine.Workflows.UseCases.SendLeadsEmail do
  @moduledoc """
  Workflow use case: send a personalised email to each lead dispatched by
  `IdentifyLeadsFromGoogleSheet`.

  Triggered by: `:lead_identified` event (dispatched as `Zaq.Event` to :engine).
  The event payload (= the Google Sheet row) is the initial input to the run.

  DAG (linear):
    ensure_person
      → build_history
      → draft_email          ← RunAgent("DraftEmail") — body returned as `output`
      → review_email         (human-in-the-loop)
      → send_email
      → increment_email_state ← Workflow.Increment — bumps the sequence counter
      → update_sheet_row      ← UpdateSheetValues single-cell (row/column/value)

  Row shape expected from the sheet (flat fields flow through the whole DAG):
    %{
      "email"        => "lead@example.com",
      "name"         => "John Doe",
      "company"      => "Acme Corp",
      "sequence"     => 2,        # current sequence counter
      "row_index"    => 5,        # 1-based sheet row number
      "position"     => "CTO",    # optional enrichment
      "industry"     => "SaaS",   # optional enrichment
      "size"         => "50-200", # optional enrichment
      "services"     => "..."     # optional enrichment
    }

  ## Usage

      {:ok, workflow} = SendLeadsEmail.create()
  """

  alias Zaq.Engine.Workflows

  @ensure_person_module "Zaq.Agent.Tools.People.EnsurePerson"
  @build_history_module "Zaq.Agent.Tools.Accounts.History"
  @draft_email_module "Zaq.Agent.Tools.Workflow.RunAgent"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @send_email_module "Zaq.Agent.Tools.People.NotifyPerson"
  @increment_module "Zaq.Agent.Tools.Workflow.Increment"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  @event_name "lead_identified"

  @doc """
  Creates the workflow and wires it to the `lead_identified` trigger.
  Returns `{:ok, workflow}`.
  """
  @spec create(keyword()) :: {:ok, Workflows.Workflow.t()} | {:error, term()}
  def create(opts \\ []) do
    Zaq.Repo.transaction(fn ->
      {:ok, workflow} = Workflows.create_workflow(build(opts))
      {:ok, trigger} = Workflows.create_trigger(%{event_name: @event_name})
      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)
      workflow
    end)
  end

  @doc """
  Returns the workflow params map. Pass opts to override defaults:
  - `:sheet_id` — Google Spreadsheet ID (default: hardcoded lead sheet)
  - `:provider` — datasource provider key (default: "google_drive")
  - `:email_state_column` — column letter for email_state (default: "I")
  - `:agent_name` — ZAQ agent name used for drafting (default: "DraftEmail")
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    sheet_id = Keyword.get(opts, :sheet_id, @sheet_id)
    provider = Keyword.get(opts, :provider, "google_drive")
    email_state_column = Keyword.get(opts, :email_state_column, "J")
    agent_name = Keyword.get(opts, :agent_name, "DraftEmail")

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
            "agent_name" => agent_name,
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
          name: "update_sheet_row",
          type: "action",
          module: @update_sheet_module,
          params: %{
            "spreadsheet_id" => sheet_id,
            "provider" => provider,
            "column" => email_state_column,
            "value_input_option" => "USER_ENTERED"
          },
          index: 6
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
          mapping: %{"value" => "ensure_person.row.sequence"}
        },
        %{
          from: "increment_email_state",
          to: "update_sheet_row",
          mapping: %{
            "row" => "ensure_person.row.row_index",
            "value" => "increment_email_state.value"
          }
        }
      ]
    }
  end
end
