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
  edge (no condition, no mapping) is rejected as a no-op, but each of ours at
  least guards, and they fan out to *different* nodes (allowed; two `start`
  edges into the *same* node would be an ambiguous double-seed). See
  `Zaq.Engine.Workflows.DagBuilder`.

  The short-circuit edge guards but deliberately does **not** map: the full
  start fact (a map) flows into `craft_email_direct`, because a scalar-mapped
  `input` would dispatch a scalar request that cannot carry the
  `machine: true` flag (see `machine_event?` handling in `TriggerNode`).

  ## DAG

      start ──(company context content NOT empty)──> craft_email_direct  (already have context → skip generation)
      start ──(company context content empty)──────> extract_company_summary
        → map_business_to_zaq          ← RunAgent: list ZAQ services + benefits
        → build_context_document       ← Concat: summary + mapping into one markdown doc
        → produce_email_topic          ← RunAgent: short, catchy email topic from the doc
        → review_summary               ← HumanInTheLoop: approve before storing
        → build_range                  ← Concat: A1 range spanning both writeback cells (L:M)
        → build_values                 ← Concat: [[email topic, context doc]] matrix
        → update_sheet_row             ← UpdateSheetValues: write topic (L) + doc (M) to the sheet
        → craft_email                  ← DispatchEvent: hand off to the email-drafting workflow

  Both branches hand off to the email-drafting workflow by dispatching the same
  `craft_email` event (as a machine/actorless run) — both forward the fact reaching
  the dispatch node — but through **two separate single-parent nodes** (`craft_email_direct`
  and `craft_email`), NOT one shared convergence node. A Runic Step with
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
  - The writeback writes the email topic (`produce_email_topic.output`) to column L
    and the context document (`build_context_document.result`) to the "company context
    content" column (M) in one range update, so the next run's `start` guard sees a
    non-empty value and takes the `craft_email` short-circuit instead of regenerating.
    The topic column feeds `SendLeadsEmail` as `start.email topic`.
  - On the **generation** branch the current run's trigger row still carries an empty
    `email topic` / `company context content` (they were empty when the sheet was
    read), so `craft_email` overrides both via its `DispatchEvent` `input` with the
    freshly generated values (`produce_email_topic.output` / `build_context_document.result`).
    Without this override `SendLeadsEmail` would see the empty originals until the
    *next* scan re-read the sheet. The short-circuit branch (`craft_email_direct`)
    needs no override — it forwards the already-populated stored row.

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
  @sheet_id "1sYIdoX6KWDCyapowvfrfebE71gUWQo3A5S_GqpXXarI"
  # Bind to the event IdentifyLeadsFromGoogleSheet already dispatches.
  @event_name "lead_identified"
  # Event dispatched to hand off to the email-drafting workflow.
  @craft_email_event "craft_email"
  # Column letters written back to the lead sheet in one range: the short/catchy
  # email topic → L, the full context document → M.
  @email_topic_column "L"
  @summary_column "M"
  # Configured agent that researches + summarizes the company.
  @summary_agent_id 5
  # Configured agent that maps the summary to ZAQ services.
  @mapping_agent_id 4
  # Configured agent that writes the short, catchy email topic.
  @topic_agent_id 6

  @doc """
  Creates the workflow and wires it to the `lead_identified` trigger.
  Returns `{:ok, workflow}`.

  Options (all optional):
  - `:sheet_id`            — Google Spreadsheet ID (default: the shared lead sheet)
  - `:provider`            — datasource provider key (default: `"google_drive"`)
  - `:summary_agent_id`    — ID of the configured summary agent (default: `4`)
  - `:mapping_agent_id`    — ID of the configured service-mapping agent (default: `5`)
  - `:topic_agent_id`      — ID of the configured email-topic agent (default: `1`)
  - `:email_topic_column`  — sheet column letter for the email topic (default: `"L"`)
  - `:summary_column`      — sheet column letter for the context doc (default: `"M"`)
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
    topic_agent_id = Keyword.get(opts, :topic_agent_id, @topic_agent_id)
    email_topic_column = Keyword.get(opts, :email_topic_column, @email_topic_column)
    summary_column = Keyword.get(opts, :summary_column, @summary_column)

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
        # Short-circuit branch (context already present). Here `produce_email_topic`
        # and `build_context_document` never run, so the two keys come from the STORED
        # sheet row (`start.email topic` / `start.company context content`, written by a
        # prior run). They already flatten into the payload from the `start` cascade
        # entry; setting them explicitly via `input` gives both dispatch nodes an
        # identical payload contract and pins the two keys `SendLeadsEmail` depends on
        # against any future cascade-key collision on this branch.
        %{
          name: "craft_email_direct",
          type: "action",
          module: @dispatch_event_module,
          params: %{
            "event_name" => @craft_email_event,
            "machine" => true,
            "input" => %{
              "email topic" => "{{start.email topic}}",
              "company context content" => "{{start.company context content}}"
            }
          },
          index: 1
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
          index: 2
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
          index: 3
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
          index: 4
        },
        # Distil the context doc into a short, catchy email topic. Written back to the
        # sheet (column L) and later read by SendLeadsEmail as `start.email topic`.
        %{
          name: "produce_email_topic",
          type: "action",
          module: @run_agent_module,
          params: %{
            "agent_id" => topic_agent_id,
            "input" =>
              "Write ONE email subject line for a cold outreach email to this company. " <>
                "Requirements: short and catchy (aim for 4–8 words, under 60 characters); " <>
                "lead with the single most compelling value proposition ZAQ offers THIS " <>
                "specific company; reference their actual business (no generic filler); and " <>
                "make it curiosity-driving so the recipient opens the email. Output ONLY the " <>
                "subject line as plain text — no surrounding quotes, no \"Subject:\" prefix, " <>
                "and no commentary. Company context:\n\n{{document}}"
          },
          index: 5
        },
        %{
          name: "review_summary",
          type: "action",
          module: @human_in_the_loop_module,
          params: %{
            "message" =>
              "Review and approve the company summary and ZAQ service mapping before storing them."
          },
          index: 6
        },
        # Build the A1 range spanning both writeback cells, e.g. "Sheet1!L5:M5"
        # (L = email topic, M = context doc).
        %{
          name: "build_range",
          type: "action",
          module: @concat_module,
          params: %{
            "parts" => ["Sheet1!{{column_email}}{{row}}:{{column_summary}}{{row}}"],
            "column_email" => email_topic_column,
            "column_summary" => summary_column
          },
          index: 9
        },
        # Wrap the email topic + document content as a 1x2 matrix ([[topic, summary]])
        # for the range update. `as_matrix` is NOT used: it joins all parts into ONE
        # string and wraps a 1x1 matrix, which would drop both values into a single
        # cell. Instead we use Concat's list mode — a single part that is a nested row
        # list. Concat flattens one level over `parts`, so the row is nested one extra
        # deep here; the whole-string placeholders keep each cell's raw value.
        %{
          name: "build_values",
          type: "action",
          module: @concat_module,
          params: %{"parts" => [[["{{email_topic}}", "{{summary}}"]]]},
          index: 10
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
          index: 11
        },
        # Post-generation branch (after the writeback). The dispatched payload is the
        # flattened run cascade, in which the trigger row's `email topic` and `company
        # context content` are still EMPTY (they were empty when the sheet was read),
        # and the freshly generated values live under colliding generic keys
        # (`produce_email_topic.output`, `build_context_document.result`). `input`
        # overrides both keys with the actual generated values (cascade-aware
        # placeholder resolution, wins on merge) so `SendLeadsEmail` reads a real
        # `start.email topic` / `start.company context content` on this same run.
        %{
          name: "craft_email",
          type: "action",
          module: @dispatch_event_module,
          params: %{
            "event_name" => @craft_email_event,
            "machine" => true,
            "input" => %{
              "email topic" => "{{produce_email_topic.output}}",
              "company context content" => "{{build_context_document.result}}"
            }
          },
          index: 12
        }
      ],
      edges: [
        # Entry fork on the reserved `start` origin. Context already present →
        # short-circuit straight to email drafting, carrying the stored content.
        %{
          from: "start",
          to: "craft_email_direct",
          condition: %{"field" => "start.company context content", "op" => "not_empty"}
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
        # Deliver the context doc as a flat `{{document}}` var — RunAgent substitution
        # only matches `\\w+`, so a dotted `{{build_context_document.result}}` would not
        # resolve. The mapping renames the cascade path to a plain var the prompt uses.
        %{
          from: "build_context_document",
          to: "produce_email_topic",
          condition: %{"field" => "result", "op" => "not_empty"},
          mapping: %{"document" => "build_context_document.result"}
        },
        # RunAgent emits `output` (not `result`); gate the HITL on it.
        %{
          from: "produce_email_topic",
          to: "review_summary",
          condition: %{"field" => "output", "op" => "not_empty"}
        },
        %{
          from: "review_summary",
          to: "build_range",
          condition: %{"field" => "approved", "op" => "eq", "value" => true},
          mapping: %{"row" => "start.row_index"}
        },
        # Write the email topic (L) and the context document (M) in one range update.
        %{
          from: "build_range",
          to: "build_values",
          mapping: %{
            "email_topic" => "produce_email_topic.output",
            "summary" => "build_context_document.result"
          }
        },
        %{
          from: "build_values",
          to: "update_sheet_row",
          mapping: %{"range" => "build_range.result", "values" => "build_values.list"}
        },
        # Writeback done → hand off to email drafting.
        %{
          from: "update_sheet_row",
          to: "craft_email"
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
