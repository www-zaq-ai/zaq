defmodule Zaq.Engine.Workflows.NestedActionSchemaContractTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Jido.Action.Schema
  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.People.NotifyPerson
  alias Zaq.Agent.Tools.Workflow.{Condition, ScheduleAction, ToUtcDateTime}
  alias Zaq.Engine.ActionSchedules
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.EdgeCondition

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defmodule NotificationRouter do
    @moduledoc false

    def dispatch(%Zaq.Event{} = event) do
      %{
        event
        | response:
            {:ok,
             %{
               status: :sent,
               channel: "email:smtp",
               channel_identifier: "person@example.com",
               notification_log_id: 123
             }}
      }
    end
  end

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    previous_router = Application.get_env(:zaq, :workflow_step_node_router, :not_configured)
    Application.put_env(:zaq, :workflow_step_node_router, NotificationRouter)

    on_exit(fn ->
      case previous_router do
        :not_configured -> Application.delete_env(:zaq, :workflow_step_node_router)
        router -> Application.put_env(:zaq, :workflow_step_node_router, router)
      end
    end)

    :ok
  end

  describe "ToUtcDateTime nested delay contract" do
    test "executes a valid delay after the workflow JSONB round-trip" do
      {run, persisted_params} =
        persisted_run(ToUtcDateTime, %{delay: %{amount: 15, unit: "minutes"}})

      assert persisted_params == %{"delay" => %{"amount" => 15, "unit" => "minutes"}}
      assert {:ok, %{status: "completed"}} = Workflows.start_run(run)

      result = Workflows.get_terminal_step_run(run.id, "action").results
      assert {:ok, datetime, 0} = DateTime.from_iso8601(result["datetime"])
      assert DateTime.diff(datetime, DateTime.utc_now(), :second) in 890..900
    end

    for {field, delay, code, path} <- [
          {:amount, %{amount: 0, unit: "minutes"}, "greater_than_or_equal_to",
           ["delay", "amount"]},
          {:unit, %{amount: 1, unit: "fortnight"}, "invalid_enum_value", ["delay", "unit"]}
        ] do
      test "rejects invalid delay.#{field} through Jido input validation" do
        {run, _persisted_params} =
          persisted_run(ToUtcDateTime, %{delay: unquote(Macro.escape(delay))})

        assert {:ok, %{status: "failed"}} = Workflows.start_run(run)

        errors = Workflows.get_terminal_step_run(run.id, "action").errors
        assert errors["type"] == "validation_error"

        assert [%{"code" => unquote(code), "path" => unquote(path)}] =
                 errors["details"]["errors"]
      end
    end

    test "generated tool schema describes the owned delay object" do
      delay = ToUtcDateTime |> tool_schema() |> property(:delay)
      properties = schema_value(delay, :properties)

      assert schema_type(delay) == "object"
      assert is_map(properties)

      amount = schema_value(properties, :amount)
      unit = schema_value(properties, :unit)

      assert required_keys(delay) == MapSet.new(["amount", "unit"])
      assert schema_type(amount) == "integer"
      assert schema_value(amount, :minimum) == 1

      assert MapSet.new(schema_value(unit, :enum), &to_string/1) ==
               MapSet.new(~w[second seconds minute minutes hour hours day days])
    end
  end

  describe "ScheduleAction opaque params contract" do
    test "preserves arbitrary nested JSON until target-Action validation" do
      schedule_id = "nested-contract-#{System.unique_integer([:positive])}"
      scheduled_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      payload = %{
        "domain_key" => %{
          "nested" => [%{"flag" => true}, %{"count" => 2}],
          "labels" => ["one", "two"]
        },
        "unknown" => "keep"
      }

      {run, persisted_params} =
        persisted_run(ScheduleAction, %{
          schedule_id: schedule_id,
          action_key: "basic.noop",
          params: payload,
          scheduled_at: scheduled_at
        })

      assert persisted_params["params"] == payload
      assert {:ok, %{status: "completed"}} = Workflows.start_run(run)

      job = ActionSchedules.get_pending_schedule(schedule_id)
      assert job.args["params"] == payload
    end

    test "generated tool schema leaves target params opaque and open" do
      params = ScheduleAction |> tool_schema() |> property(:params)

      assert schema_type(params) == "object"
      refute has_schema_key?(params, :properties)
      refute schema_value(params, :additionalProperties, true) == false
    end
  end

  describe "NotifyPerson nested person contract" do
    test "accepts required id and every documented optional field after JSONB reload" do
      person = %{
        id: 123,
        full_name: "Ada Lovelace",
        email: "ada@example.com",
        phone: "+961123456",
        role: "Engineer",
        status: "active",
        incomplete: false
      }

      {run, persisted_params} =
        persisted_run(NotifyPerson, %{person: person, subject: "Hello", message: "Body"})

      assert persisted_params["person"] == stringify_keys(person)
      assert {:ok, %{status: "completed"}} = Workflows.start_run(run)

      result = Workflows.get_terminal_step_run(run.id, "action").results
      assert result["person"] == stringify_keys(person)
      assert result["person_id"] == 123
    end

    test "requires person.id through Jido input validation" do
      {run, _persisted_params} =
        persisted_run(NotifyPerson, %{person: %{}, subject: "Hello", message: "Body"})

      assert {:ok, %{status: "failed"}} = Workflows.start_run(run)

      errors = Workflows.get_terminal_step_run(run.id, "action").errors
      assert errors["type"] == "validation_error"

      assert [%{"code" => "required", "path" => ["person", "id"]}] =
               errors["details"]["errors"]
    end

    test "generated tool schema exposes id and the documented optional fields" do
      person = NotifyPerson |> tool_schema() |> property(:person)
      properties = schema_value(person, :properties)

      assert schema_type(person) == "object"
      assert is_map(properties)
      assert required_keys(person) == MapSet.new(["id"])
      assert schema_type(property(person, :id)) == "integer"

      assert properties |> Map.keys() |> MapSet.new(&to_string/1) ==
               MapSet.new(~w[id full_name email phone role status incomplete])

      refute schema_value(person, :additionalProperties, true) == false
    end
  end

  describe "Condition structured conditions contract" do
    test "evaluates structured conditions against a map input after the JSONB round-trip" do
      conditions = [
        %{"key" => "role", "op" => "eq", "value" => "CFO"},
        %{"key" => "age", "op" => "gte", "value" => 18},
        %{"key" => "tier", "op" => "eq", "value" => "gold", "default" => "gold"}
      ]

      {run, persisted_params} =
        persisted_run(Condition, %{
          input: %{"role" => "CFO", "age" => 24},
          conditions: conditions
        })

      # The condition objects must survive persistence and StepRunner/Jido conversion
      # as objects — this is the shape the published tool schema has to describe.
      assert persisted_params["conditions"] == conditions
      assert persisted_params["input"] == %{"role" => "CFO", "age" => 24}
      assert {:ok, %{status: "completed"}} = Workflows.start_run(run)

      result = Workflows.get_terminal_step_run(run.id, "action").results
      assert result["passed"] == true
      assert result["input"] == %{"role" => "CFO", "age" => 24}
    end

    test "routing mode returns condition objects, not strings, after the JSONB round-trip" do
      {run, _persisted_params} =
        persisted_run(Condition, %{
          input: %{"role" => "CTO"},
          conditions: [%{"key" => "role", "op" => "eq", "value" => "CFO"}],
          on_fail: "continue"
        })

      assert {:ok, %{status: "completed"}} = Workflows.start_run(run)

      result = Workflows.get_terminal_step_run(run.id, "action").results
      assert result["passed"] == false
      refute Map.has_key?(result, "input")

      assert [%{"key" => "role", "op" => "eq", "value" => "CFO"}] = result["failed_conditions"]
    end

    test "generated tool schema publishes input as object-or-string" do
      input = Condition |> tool_schema() |> property(:input)

      assert MapSet.member?(required_keys(tool_schema(Condition)), "input")

      assert is_list(schema_value(input, :anyOf)),
             "input must publish both branches of its union, got: #{inspect(input)}"

      assert input |> schema_value(:anyOf) |> MapSet.new(&schema_type/1) ==
               MapSet.new(["object", "string"])
    end

    test "generated tool schema publishes conditions as structured objects" do
      conditions = Condition |> tool_schema() |> property(:conditions)
      items = schema_value(conditions, :items)
      properties = schema_value(items, :properties)

      assert schema_type(conditions) == "array"
      assert schema_type(items) == "object"
      assert is_map(properties)
      assert required_keys(items) == MapSet.new(["key"])

      assert properties |> Map.keys() |> MapSet.new(&to_string/1) ==
               MapSet.new(~w[key value op type default])

      assert schema_type(schema_value(properties, :key)) == "string"

      assert properties |> schema_value(:op) |> schema_value(:enum) |> MapSet.new(&to_string/1) ==
               MapSet.new(EdgeCondition.ops(), &to_string/1)

      assert properties |> schema_value(:type) |> schema_value(:enum) |> MapSet.new(&to_string/1) ==
               MapSet.new(~w[date datetime])
    end

    test "generated tool schema publishes the documented defaults" do
      schema = tool_schema(Condition)
      on_fail = property(schema, :on_fail)

      assert MapSet.new(schema_value(on_fail, :enum), &to_string/1) ==
               MapSet.new(~w[halt continue])

      assert schema_value(on_fail, :default) == "halt"
      assert schema_value(property(schema, :conditions), :default) == []
    end

    test "generated output schema describes the passthrough input and failed conditions" do
      schema = output_schema(Condition)
      failed_conditions = property(schema, :failed_conditions)

      assert schema_type(property(schema, :passed)) == "boolean"
      assert schema_type(property(schema, :input)) == "object"
      assert schema_type(failed_conditions) == "array"
      assert schema_type(schema_value(failed_conditions, :items)) == "object"
    end
  end

  defp persisted_run(action, params) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Nested contract #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "action",
            type: "action",
            module: inspect(action),
            params: params,
            index: 0
          }
        ],
        edges: []
      })

    {:ok, run} = Workflows.create_run(workflow, @source_event)
    reloaded = Workflows.get_run!(run.id)
    [node] = reloaded.steps_snapshot["nodes"]

    {reloaded, node["params"]}
  end

  defp tool_schema(action), do: Tool.to_tool(action).parameters_schema

  defp output_schema(action), do: Schema.to_json_schema(action.output_schema())

  defp property(schema, key) do
    schema
    |> schema_value(:properties)
    |> schema_value(key)
  end

  defp required_keys(schema) do
    schema
    |> schema_value(:required)
    |> MapSet.new(&to_string/1)
  end

  defp schema_type(schema), do: schema |> schema_value(:type) |> to_string()

  defp has_schema_key?(schema, key),
    do: Map.has_key?(schema, key) or Map.has_key?(schema, to_string(key))

  defp schema_value(schema, key), do: schema_value(schema, key, :missing)

  defp schema_value(schema, key, default) do
    case Map.fetch(schema, key) do
      {:ok, value} -> value
      :error -> Map.get(schema, to_string(key), default)
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
