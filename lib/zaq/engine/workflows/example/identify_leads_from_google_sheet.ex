defmodule Zaq.Engine.Workflows.UseCases.IdentifyLeadsFromGoogleSheet do
  @moduledoc """
  Workflow use case: fetch leads from a Google Sheet and dispatch qualifying rows.

  DAG:
    get_sheet ──> extract_rows ──(rows not empty)──> process_rows
      process_rows (a `Batch` action, per-row fan-out over `items`):
        process:      [check_active, check_email_state, dispatch_lead]
        post_process: [sleep_between]

  `process_rows` is a `type: "action"` `Batch` node — iteration is never authored
  as a public `map` type. `Batch` lowers itself onto the internal `map` primitive
  at build time. `delivery: "item"` makes each row its own fan-out unit, so each row
  becomes its own per-fork `StepRun` (`process_rows/<step>[i]`) plus one aggregate
  row; `strategy: "skip_and_continue"` isolates a failing row without aborting the
  run.

  A lead qualifies when: active == true AND sequence < 4.
  Qualifying rows are dispatched as Zaq.Event payloads to :engine with name :lead_identified.

  ## Usage

      {:ok, workflow} = IdentifyLeadsFromGoogleSheet.create()
  """

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.Helper

  @get_sheet_module "Zaq.Agent.Tools.Sheets.GetSheet"
  @extract_rows_module "Zaq.Agent.Tools.Sheets.ExtractRows"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"
  @dispatch_event_module "Zaq.Agent.Tools.Workflow.DispatchEvent"
  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"

  @sheet_id "1omtYyzwy8xrkW2Mi-AU76DsRIOoC1xqNFFPAz2uR-nI"
  @lead_identified_event "lead_identified"
  @trigger_event "identify_leads_scan"
  @cron_schedule "0 9 * * *"

  @doc """
  Creates the workflow and wires it to a cron trigger that scans the sheet on a
  schedule. Returns `{:ok, workflow}`.

  This workflow is the *producer* of `lead_identified` events (consumed by
  `SendLeadsEmail`), so it is started on a schedule rather than by an event.

  Options:
  - `:sheet_id` — Google Spreadsheet ID (default: hardcoded lead sheet)
  - `:provider` — datasource provider key (default: "google_drive")
  - `:cron_schedule` — 5-field cron expression (default: `"0 9 * * *"`, daily 09:00)
  """
  @spec create(keyword()) :: {:ok, Workflows.Workflow.t()} | {:error, term()}
  def create(opts \\ []) do
    sheet_id = Keyword.get(opts, :sheet_id, @sheet_id)
    provider = Keyword.get(opts, :provider, "google_drive")
    cron_schedule = Keyword.get(opts, :cron_schedule, @cron_schedule)

    Helper.create_workflow_with_trigger(build(sheet_id, provider), %{
      event_name: @trigger_event,
      trigger_type: "cron",
      cron_schedule: cron_schedule
    })
  end

  @doc """
  Returns workflow params for `Zaq.Engine.Workflows.create_workflow/1`.

  - `sheet_id` — Google Spreadsheet ID
  - `provider` — datasource provider key (default: "google_drive")
  """
  @spec build(String.t(), String.t()) :: map()
  def build(sheet_id, provider \\ "google_drive") do
    %{
      name: "Identify Leads from Google Sheet",
      description: "Zaq's use case workflow for identifying leads from a Google Sheet",
      status: "active",
      nodes: [
        %{
          name: "get_sheet",
          type: "action",
          module: @get_sheet_module,
          params: %{
            "provider" => provider,
            "spreadsheet_id" => sheet_id
          },
          index: 0
        },
        %{
          name: "extract_rows",
          type: "action",
          module: @extract_rows_module,
          params: %{},
          index: 1
        },
        %{
          name: "process_rows",
          type: "action",
          module: @batch_module,
          # Iteration is expressed through the `Batch` action — never a public
          # `map` node. `Batch` lowers this onto the internal `map` primitive at
          # build time (per-row fan-out over `items`, supplied by the incoming
          # edge mapping). `delivery: "item"` makes each row its own fan-out unit,
          # so every row gets its own `StepRun`. The delivery field is read from
          # the body's first action's input schema.
          params: %{
            "delivery" => "item",
            "strategy" => "skip_and_continue",
            "batch_size" => 1,
            "process" => [
              %{
                "name" => "check_active",
                "type" => "action",
                "module" => @condition_module,
                "params" => %{
                  "conditions" => [%{"key" => "active", "value" => true}]
                }
              },
              %{
                "name" => "check_email_state",
                "type" => "action",
                "module" => @condition_module,
                "params" => %{
                  "conditions" => [
                    %{"key" => "sequence", "op" => "lt", "value" => 4, "default" => 0}
                  ]
                }
              },
              %{
                "name" => "dispatch_lead",
                "type" => "action",
                "module" => @dispatch_event_module,
                "params" => %{
                  "event_name" => to_string(@lead_identified_event),
                  # Mark the dispatched run as a machine (actorless) run so the
                  # SendLeadsEmail DAG's build_history step can fetch the lead's
                  # history via its mapped person_id. NOTE: this is currently an
                  # unconditional opt-in; per-principal authorization (who may
                  # run/edit a workflow) is tracked under workflow resource
                  # management.
                  "machine" => true
                }
              }
            ],
            "post_process" => [
              %{
                "name" => "sleep_between",
                "type" => "action",
                "module" => @sleep_module,
                "params" => %{"duration_ms" => 10_000}
              }
            ]
          },
          index: 2
        }
      ],
      edges: [
        %{
          from: "get_sheet",
          to: "extract_rows",
          condition: %{"field" => "record", "op" => "not_empty"}
        },
        %{
          from: "extract_rows",
          to: "process_rows",
          condition: %{"field" => "rows", "op" => "not_empty"},
          mapping: %{"items" => "rows"}
        }
      ]
    }
  end

  # ── Reference: original DispatchLead (inline, was working) ───────────────────
  #
  # defmodule DispatchLead do
  #   use Jido.Action,
  #     name: "dispatch_lead",
  #     schema: [input: [type: :map, required: true]],
  #     output_schema: [dispatched: [type: :map, required: true]]
  #
  #   use Zaq.Engine.Workflows.Action
  #
  #   def run(%{input: row}, _ctx) do
  #     string_row = Map.new(row, fn {k, v} -> {to_string(k), v} end)
  #     event = Zaq.Event.new(string_row, :engine, type: :async, name: "lead_identified")
  #
  #     case Zaq.NodeRouter.dispatch(event).response do
  #       {:ok, _} -> {:ok, %{dispatched: string_row}}
  #       {:error, reason} -> {:error, inspect(reason)}
  #     end
  #   end
  # end
end
