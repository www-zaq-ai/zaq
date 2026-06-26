defmodule Zaq.Engine.Workflows.UseCases.GenerateCompanyContext do
  @moduledoc """
  Workflow use case: build (or load) a per-company context document for each lead
  dispatched by `IdentifyLeadsFromGoogleSheet`.

  Triggered by: the `lead_identified` event (the *same* event `SendLeadsEmail`
  listens to). `IdentifyLeadsFromGoogleSheet` is the producer of that event — it
  dispatches one `Zaq.Event` per qualifying sheet row to `:engine` with
  `name: "lead_identified"`. `TriggerNode.fire/2` starts **every** active workflow
  bound to that event name, so this workflow and `SendLeadsEmail` both run for each
  lead. This mirrors `SendLeadsEmail` exactly: we only create a trigger that binds
  to the already-dispatched event — the producer is not modified. If you want the
  two to be decoupled, give this workflow its own `event_name` and add a second
  `DispatchEvent` step inside `IdentifyLeadsFromGoogleSheet`.

  ## The `start` namespace (trigger payload contract)

  The trigger payload (the Google Sheet row) is kept for the whole run in the
  persistent `start` namespace. Any edge `mapping` or `Condition` key reads a field
  from it via a `start.<field>` dotted path. Header keys are **downcased column
  headers with spaces preserved** (see `Sheets.ExtractRows`), so a "Company Official
  Name" column is read as `start.company official name`.

  Row shape expected from the trigger (each field readable as `start.<field>`):
    %{
      "company official name" => "Acme Corp",        # → start.company official name
      "company website"       => "https://acme.com", # → start.company website
      "company context file"  => "" | "<drive_id>",  # empty = no context yet
      "row_index"             => 5                    # 1-based sheet row → start.row_index
    }

  ## DAG

      start ──(context file present)──> load_existing_context   (leaf)
      start ──(context file empty)────> extract_company_summary
        → map_business_to_zaq          ← RunAgent: list ZAQ services + benefits
        → build_context_document       ← Concat: summary + mapping into one markdown doc
        → review_summary               ← HumanInTheLoop: approve before storing
        → create_company_folder        ← CreateDocument: a Drive folder named after the company
        → store_context                ← CreateDocument: company_context.md inside that folder
        → build_range                  ← Concat: A1 range string for the writeback cell
        → build_values                 ← Concat: wrap the new doc id as a [[value]] matrix
        → update_sheet_row             ← UpdateSheetValues: write the doc id back to the sheet

  The writeback closes the loop: the new document id is written to the row's
  "company context file" column, so the next run's `start` guard sees a non-empty
  value and takes the `load_existing_context` branch instead of regenerating.

  ## Notes on the fixes applied vs. the original draft

  - Branching uses two `from: "start"` edges, NOT a `Condition` node. A `Condition`
    action only resolves TOP-LEVEL fact keys (it cannot reach the `start` namespace,
    which lives under `__cascade__`), and its default `on_fail: :halt` fails the run
    on the common empty-cell case instead of routing. The start-sentinel guards read
    the planted trigger row directly; the unmatched branch is skipped, not failed.
  - `start.<field>` works in downstream edge *mappings* (EdgeStep traverses
    `__cascade__`), but NOT inside a `Condition` node. At the root, the trigger row is
    the flat top-level fact, so the `start` guards read bare keys (`company context
    file`); later edges read `start.company official name` / `start.row_index`.
  - `RunAgent` requires **`agent_id` (integer)**, never `agent_name` — see its schema.
  - `{{variable}}` substitution matches `\\w+` only (no spaces), so edge `mapping`
    renames spaced sheet columns to snake_case targets (`company_official_name`) that
    the prompts interpolate as `{{company_official_name}}`.
  - Cascade reads are node-qualified: `create_company_folder.record.id`,
    `store_context.record.id` — a bare `record.id` would look for a node named
    `record`.
  - The "concatenate summary + mapping" step (previously blocked on issue #510) is a
    plain `Concat` with two fixed parts — no new tool needed.

  ## Usage

      {:ok, workflow} = GenerateCompanyContext.create()
  """

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.Helper

  @download_document_module "Zaq.Agent.Tools.DataSource.DownloadDocument"
  @run_agent_module "Zaq.Agent.Tools.Workflow.RunAgent"
  @concat_module "Zaq.Agent.Tools.Workflow.Concat"
  @human_in_the_loop_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @create_document_module "Zaq.Agent.Tools.DataSource.CreateDocument"
  @update_sheet_module "Zaq.Agent.Tools.Sheets.UpdateSheetValues"

  # Same lead sheet the producer (IdentifyLeadsFromGoogleSheet) scans.
  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  # Parent Drive folder under which each company's folder is created.
  @parent_folder_id "1SGcI2abo8vtKDXdexjnHXv3iu1srjuXZ"
  # Bind to the event IdentifyLeadsFromGoogleSheet already dispatches.
  @event_name "lead_identified"
  # Column letter of the "Company context file" cell we write the new doc id back to.
  @context_file_column "K"
  # Configured agent used for the summary/mapping steps (the draft used the name "Al").
  @agent_id 1

  @doc """
  Creates the workflow and wires it to the `lead_identified` trigger.
  Returns `{:ok, workflow}`.

  Options (all optional):
  - `:sheet_id`       — Google Spreadsheet ID (default: the shared lead sheet)
  - `:provider`       — datasource provider key (default: `"google_drive"`)
  - `:parent_folder_id` — Drive folder under which company folders are created
  - `:agent_id`       — ID of the configured ZAQ agent (default: `1`)
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
    parent_folder_id = Keyword.get(opts, :parent_folder_id, @parent_folder_id)
    agent_id = Keyword.get(opts, :agent_id, @agent_id)
    context_file_column = Keyword.get(opts, :context_file_column, @context_file_column)

    %{
      name: "Generate Company Context",
      description: "Build or load a per-company context document for each identified lead",
      status: "active",
      nodes: [
        # Branching happens entirely in the two `from: "start"` edges below — no
        # Condition node. A Condition action only resolves TOP-LEVEL fact keys and
        # cannot reach the `start` namespace (which lives under `__cascade__`), and
        # its default `on_fail: :halt` would fail the run on the (common) empty-cell
        # case instead of routing. The start-sentinel edges read the planted trigger
        # row directly and skip (non-fatally) the branch whose guard does not match.

        # "context file" cell is non-empty → the document already exists → load it
        # (leaf branch).
        %{
          name: "load_existing_context",
          type: "action",
          module: @download_document_module,
          params: %{"provider" => provider},
          index: 1
        },
        # "context file" cell is empty → no context yet → research + summarize.
        %{
          name: "extract_company_summary",
          type: "action",
          module: @run_agent_module,
          params: %{
            "agent_id" => agent_id,
            "input" =>
              "Run a web search to obtain a clear understanding of the main business " <>
                "{{company_official_name}} operates in. You can also use their official " <>
                "website at {{company_website}}. Craft a clear, concise summary of this company."
          },
          index: 2
        },
        %{
          name: "map_business_to_zaq",
          type: "action",
          module: @run_agent_module,
          params: %{
            "agent_id" => agent_id,
            "input" =>
              "Based on the following company summary: {{summary}}, write a concise list of the " <>
                "top services ZAQ can provide to this business. For each, give a clear benefit and " <>
                "a short explanation of why it is relevant."
          },
          index: 3
        },
        # Concatenate summary + service mapping into a single markdown document.
        # Concat substitutes {{key}} from the other input params (mapped in below)
        # and joins the parts with the separator. Replaces the issue #510 gap.
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
          index: 4
        },
        %{
          name: "review_summary",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{
            "message" =>
              "Review and approve the company summary and ZAQ service mapping before storing them."
          },
          index: 5
        },
        # Create the per-company Drive folder. `name` comes from the trigger row.
        %{
          name: "create_company_folder",
          type: "action",
          module: @create_document_module,
          params: %{
            "provider" => provider,
            "mime_type" => "application/vnd.google-apps.folder",
            "parent_id" => parent_folder_id
          },
          index: 6
        },
        # Store the markdown document inside the folder created above.
        %{
          name: "store_context",
          type: "action",
          module: @create_document_module,
          params: %{
            "provider" => provider,
            "name" => "company_context.md",
            "mime_type" => "text/markdown"
          },
          index: 7
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
        # Wrap the new document id as a 1x1 matrix for the range update.
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
        # Two `from: "start"` guards branch directly off the planted trigger row.
        # The engine plants the row as the initial fact (flat, top-level keys — the
        # downcased sheet headers, spaces preserved), so the condition `field` and
        # the mapping sources are BARE top-level keys here (no `start.` prefix — that
        # prefix only resolves in downstream edges via `__cascade__`). The guard whose
        # condition is not met is recorded as a skipped edge, not a failure.

        # context file present → load it. `document_id` is required by DownloadDocument
        # and comes from the row's context-file cell.
        %{
          from: "start",
          to: "load_existing_context",
          condition: %{"field" => "company context file", "op" => "not_empty"},
          mapping: %{"document_id" => "company context file"}
        },
        # context file empty → generate. Rename the spaced sheet columns to snake_case
        # so the prompt can interpolate them as {{company_official_name}} / {{company_website}}.
        %{
          from: "start",
          to: "extract_company_summary",
          condition: %{"field" => "company context file", "op" => "empty"},
          mapping: %{
            "company_official_name" => "company official name",
            "company_website" => "company website"
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
          to: "create_company_folder",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{"name" => "start.company official name"}
        },
        # Store the doc inside the just-created folder; node-qualified cascade reads.
        %{
          from: "create_company_folder",
          to: "store_context",
          condition: %{"field" => "record", "op" => "not_empty"},
          mapping: %{
            "parent_id" => "create_company_folder.record.id",
            "content" => "build_context_document.result"
          }
        },
        %{
          from: "store_context",
          to: "build_range",
          condition: %{"field" => "record", "op" => "not_empty"},
          mapping: %{"row" => "start.row_index"}
        },
        %{
          from: "build_range",
          to: "build_values",
          mapping: %{"value" => "store_context.record.id"}
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
