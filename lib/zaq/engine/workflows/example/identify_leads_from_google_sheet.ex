defmodule Zaq.Engine.Workflows.UseCases.IdentifyLeadsFromGoogleSheet do
  @moduledoc """
  Workflow use case: fetch leads from a Google Sheet and dispatch qualifying rows.

  DAG:
    get_sheet ──> extract_rows ──(rows not empty)──> batch_rows
      batch_rows.process:      [iterate_rows (inline)]
      batch_rows.post_process: [sleep_between (inline)]
        iterate_rows.pipeline: [check_active, check_email_state, dispatch_lead]

  A lead qualifies when: active == true AND email_state < 4.
  Qualifying rows are dispatched as Zaq.Event payloads to :engine with name :lead_identified.

  ## Usage

      {:ok, workflow} = IdentifyLeadsFromGoogleSheet.create()
  """

  alias Zaq.Engine.Workflows

  @get_sheet_module "Zaq.Agent.Tools.Sheets.GetSheet"
  @extract_rows_module "Zaq.Agent.Tools.Sheets.ExtractRows"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @iterate_module "Zaq.Agent.Tools.Workflow.Iterate"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"
  @dispatch_event_module "Zaq.Agent.Tools.Workflow.DispatchEvent"
  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"

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

    Zaq.Repo.transaction(fn ->
      {:ok, workflow} = Workflows.create_workflow(build(sheet_id, provider))

      {:ok, trigger} =
        Workflows.create_trigger(%{
          event_name: @trigger_event,
          trigger_type: "cron",
          cron_schedule: cron_schedule
        })

      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)
      workflow
    end)
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
          name: "batch_rows",
          type: "action",
          module: @batch_module,
          params: %{
            "batch_size" => 50,
            "strategy" => "skip_and_continue",
            "process" => [
              %{
                "name" => "iterate_rows",
                "type" => "action",
                "module" => @iterate_module,
                "params" => %{
                  "strategy" => "skip_and_continue",
                  "pipeline" => [
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
                          %{"key" => "email_state", "op" => "lt", "value" => 4, "default" => 0}
                        ]
                      }
                    },
                    %{
                      "name" => "dispatch_lead",
                      "type" => "action",
                      "module" => @dispatch_event_module,
                      "params" => %{
                        "event_name" => to_string(@lead_identified_event)
                      }
                    }
                  ]
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
          to: "batch_rows",
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
