defmodule Zaq.Engine.Workflows.UseCases.GenerateCompanyContext do
  @moduledoc """
  Workflow use case: build (or load) a per-company context document for each lead
  dispatched by `IdentifyLeadsFromGoogleSheet`, then hand off to email drafting.

  Triggered by: the `lead_identified` event (the *same* event `SendLeadsEmail`
  listens to). `IdentifyLeadsFromGoogleSheet` is the producer of that event — it
  dispatches one `Zaq.Event` per qualifying sheet row to `:engine` with
  `name: "lead_identified"`. `TriggerNode.fire/2` starts **every** active workflow
  bound to that event name, so this workflow runs once per lead.

  ## The `start` namespace (trigger payload contract)

  The trigger payload (the Google Sheet row) is kept for the whole run in the
  persistent `start` namespace. Any edge `mapping` or `Condition` key reads a field
  from it via a `start.<field>` dotted path. Header keys are **downcased column
  headers with spaces preserved** (see `Sheets.ExtractRows`), so a "Company Official
  Name" column is read as `start.company official name`.

  Row shape expected from the trigger (each field readable as `start.<field>`):
    %{
      "company official name"   => "Acme Corp",        # → start.company official name
      "company website"         => "https://acme.com", # → start.company website
      "company context content" => "" | "<markdown>",  # empty = no context yet
      "row_index"               => 5                    # 1-based sheet row → start.row_index
    }

  ## Entry branching is on `from: "start"` edges

  Rather than a `Condition` node, the entry fork lives on two `from: "start"`
  edges. `start` is the reserved virtual origin: an edge out of it remaps/guards
  the planted initial fact before it reaches a real root node. A bare `from: "start"`
  edge (no condition, no mapping) is rejected as a no-op, but each of ours both
  guards and maps, and they fan out to *different* nodes (allowed; two `start`
  edges into the *same* node would be an ambiguous double-seed). See
  `Zaq.Engine.Workflows.DagBuilder`.

  ## DAG

      start ──(company context content NOT empty)──> craft_email_direct  (already have context → skip generation)
      start ──(company context content empty)──────> extract_company_summary
        → map_business_to_zaq          ← RunAgent: list ZAQ services + benefits
        → build_context_document       ← Concat: summary + mapping into one markdown doc
        → review_summary               ← HumanInTheLoop: approve before storing
        → build_range                  ← Concat: A1 range string for the writeback cell
        → build_values                 ← Concat: wrap the doc content as a [[value]] matrix
        → update_sheet_row             ← UpdateSheetValues: write the doc back to the sheet
        → craft_email_after_write      ← DispatchEvent: hand off to the email-drafting workflow

  Both branches hand off to the email-drafting workflow by dispatching the same
  `craft_email` event (as a machine/actorless run) carrying the context document as
  `input` — but through **two separate single-parent nodes** (`craft_email_direct`
  and `craft_email_after_write`), NOT one shared convergence node. A Runic Step with
  two inbound edges fires nondeterministically (only the parent that wins the
  reaction race triggers it), so a shared node would dispatch only intermittently.
  One dispatch node per branch keeps each single-parent and deterministic; the
  branches are mutually exclusive, so exactly one fires per run.

  ## Notes

  - `extract_company_summary` and `map_business_to_zaq` use **different** configured
    agents (`@summary_agent_id` vs `@mapping_agent_id`).
  - `RunAgent` requires **`agent_id` (integer)**, never `agent_name` — see its schema.
  - `{{variable}}` substitution matches `\\w+` only (no spaces), so edge `mapping`
    renames spaced sheet columns to snake_case targets (`company_official_name`) that
    the prompts interpolate as `{{company_official_name}}`.
  - The writeback writes `build_context_document.result` back to the row's
    "company context content" column, so the next run's `start` guard sees a
    non-empty value and takes the `craft_email` short-circuit instead of regenerating.

  ## Usage

      {:ok, workflow} = GenerateCompanyContext.create()
  """

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.Helper

  @dispatch_event_module "Zaq.Agent.Tools.Workflow.DispatchEvent"
  @run_agent_module "Zaq.Agent.Tools.Workflow.RunAgent"
  @concat_module "Zaq.Agent.Tools.Workflow.Concat"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  # Same lead sheet the producer (IdentifyLeadsFromGoogleSheet) scans.
  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  # Bind to the event IdentifyLeadsFromGoogleSheet already dispatches.
  @event_name "lead_identified"
  # Event dispatched to hand off to the email-drafting workflow.
  @craft_email_event "craft_email"
  # Column letter of the "Company context content" cell we write the doc back to.
  @context_file_column "K"
  # Configured agent that researches + summarizes the company.
  @summary_agent_id 4
  # Configured agent that maps the summary to ZAQ services.
  @mapping_agent_id 5

  @doc """
  Creates the workflow and wires it to the `lead_identified` trigger.
  Returns `{:ok, workflow}`.

  Options (all optional):
  - `:sheet_id`            — Google Spreadsheet ID (default: the shared lead sheet)
  - `:provider`            — datasource provider key (default: `"google_drive"`)
  - `:summary_agent_id`    — ID of the configured summary agent (default: `1`)
  - `:mapping_agent_id`    — ID of the configured service-mapping agent (default: `6`)
  - `:context_file_column` — sheet column letter for the writeback (default: `"K"`)
  """
  @spec create(keyword()) :: {:ok, Workflows.Workflow.t()} | {:error, term()}
  def create(opts \\ []) do
    Helper.create_workflow_with_trigger(build(opts), %{event_name: @event_name})
  end

  @doc """
  Returns the workflow params map for `Workflows.create_workflow/1`.
  See `create/1` for the supported options.
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    sheet_id = Keyword.get(opts, :sheet_id, @sheet_id)
    provider = Keyword.get(opts, :provider, "google_drive")
    summary_agent_id = Keyword.get(opts, :summary_agent_id, @summary_agent_id)
    mapping_agent_id = Keyword.get(opts, :mapping_agent_id, @mapping_agent_id)
    context_file_column = Keyword.get(opts, :context_file_column, @context_file_column)

    %{
      name: "Generate Company Context",
      description: "Build or load a per-company context document for each identified lead",
      status: "active",
      nodes: [
        # Both branches hand off to the email-drafting workflow by dispatching the
        # SAME `craft_email` event, but through TWO SEPARATE single-parent nodes.
        #
        # They are NOT a single convergence node on purpose: a Runic Step with two
        # inbound edges fires nondeterministically (only the parent that wins the
        # reaction race triggers it), so a shared `craft_email` node dispatched only
        # intermittently. One dispatch node per branch keeps each single-parent and
        # deterministic — exactly one fires per run (the branches are mutually
        # exclusive). `machine: true` marks the dispatched run as actorless so its
        # trusted-context steps accept their mapped person_id.
        #
        # Short-circuit branch (context already present).
        %{
          name: "craft_email_direct",
          type: "action",
          module: @dispatch_event_module,
          params: %{"event_name" => @craft_email_event, "machine" => true},
          index: 13
        },
        # Post-generation branch (after the writeback).
        %{
          name: "craft_email_after_write",
          type: "action",
          module: @dispatch_event_module,
          params: %{"event_name" => @craft_email_event, "machine" => true},
          index: 14
        },
        # No context yet → research + summarize the company.
        %{
          name: "extract_company_summary",
          type: "action",
          module: @run_agent_module,
          params: %{
            "agent_id" => summary_agent_id,
            "input" =>
              "Run a web search to obtain a clear understanding of the main business " <>
                "{{company_official_name}} operates in. You can also use their official " <>
                "website at {{company_website}}. Craft a clear, concise summary of this company."
          },
          index: 1
        },
        %{
          name: "map_business_to_zaq",
          type: "action",
          module: @run_agent_module,
          params: %{
            "agent_id" => mapping_agent_id,
            "input" =>
              "Based on the following company summary: {{summary}}, write a concise list of the " <>
                "top services ZAQ can provide to this business. For each, give a clear benefit and " <>
                "a short explanation of why it is relevant."
          },
          index: 2
        },
        # Concatenate summary + service mapping into a single markdown document.
        %{
          name: "build_context_document",
          type: "action",
          module: @concat_module,
          params: %{
            "parts" => [
              "## Company Summary\n\n{{summary}}",
              "## How ZAQ Can Help\n\n{{mapping}}"
            ],
            "separator" => "\n\n"
          },
          index: 3
        },
        %{
          name: "review_summary",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{
            "message" =>
              "Review and approve the company summary and ZAQ service mapping before storing them."
          },
          index: 4
        },
        # Build the A1 range for the writeback cell, e.g. "Sheet1!K5".
        %{
          name: "build_range",
          type: "action",
          module: @concat_module,
          params: %{
            "parts" => ["Sheet1!{{column}}{{row}}"],
            "column" => context_file_column
          },
          index: 8
        },
        # Wrap the document content as a 1x1 matrix for the range update.
        %{
          name: "build_values",
          type: "action",
          module: @concat_module,
          params: %{"parts" => ["{{value}}"], "as_matrix" => true},
          index: 9
        },
        %{
          name: "update_sheet_row",
          type: "action",
          module: @update_sheet_module,
          params: %{
            "provider" => provider,
            "spreadsheet_id" => sheet_id,
            "value_input_option" => "USER_ENTERED"
          },
          index: 10
        }
      ],
      edges: [
        # Entry fork on the reserved `start` origin. Context already present →
        # short-circuit straight to email drafting, carrying the stored content.
        %{
          from: "start",
          to: "craft_email_direct",
          condition: %{"field" => "start.company context content", "op" => "not_empty"},
          mapping: %{"input" => "start.company context content"}
        },
        # No context yet → generate. Rename the spaced sheet columns to snake_case
        # so the prompt can interpolate {{company_official_name}} / {{company_website}}.
        %{
          from: "start",
          to: "extract_company_summary",
          condition: %{"field" => "start.company context content", "op" => "empty"},
          mapping: %{
            "company_official_name" => "start.company official name",
            "company_website" => "start.company website"
          }
        },
        %{
          from: "extract_company_summary",
          to: "map_business_to_zaq",
          condition: %{"field" => "output", "op" => "not_empty"},
          mapping: %{"summary" => "extract_company_summary.output"}
        },
        # Carry both the summary (two nodes back) and the mapping (this node) into Concat.
        %{
          from: "map_business_to_zaq",
          to: "build_context_document",
          condition: %{"field" => "output", "op" => "not_empty"},
          mapping: %{
            "summary" => "extract_company_summary.output",
            "mapping" => "map_business_to_zaq.output"
          }
        },
        %{
          from: "build_context_document",
          to: "review_summary",
          condition: %{"field" => "result", "op" => "not_empty"}
        },
        %{
          from: "review_summary",
          to: "build_range",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{"row" => "start.row_index"}
        },
        %{
          from: "build_range",
          to: "build_values",
          mapping: %{"value" => "build_context_document.result"}
        },
        %{
          from: "build_values",
          to: "update_sheet_row",
          mapping: %{"range" => "build_range.result", "values" => "build_values.matrix"}
        },
        # Writeback done → hand off to email drafting with the generated document.
        %{
          from: "update_sheet_row",
          to: "craft_email_after_write",
          mapping: %{"input" => "build_context_document.result"}
        }
      ]
    }
  end

  # ── Reference: Drive-backed storage variant (disabled) ───────────────────────
  #
  # An earlier draft stored the context document in Google Drive (a per-company
  # folder + a company_context spreadsheet) instead of writing it back into the
  # lead sheet. It needs either a shared drive or an OAuth2-configured
  # CreateDocument call, so it is kept here for reference only:
  #
  #   create_company_folder  ← CreateDocument (mime: folder, parent_id: <folder>)
  #   store_context          ← CreateDocument (mime: spreadsheet)
  #   append_context         ← AppendSheetValues (range "A1", values ["{{summary}}"])
  #
  # with edges review_summary → create_company_folder → store_context → append_context,
  # each guarded on `record not_empty` and carrying node-qualified cascade reads
  # (`create_company_folder.record.id`, `store_context.record.id`).
end
