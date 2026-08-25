defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInputTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Workflow.ValidateWorkflowInput
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Event
  alias Zaq.Repo

  # Captures the dispatched event instead of routing it, so the boundary the tool
  # crosses is asserted rather than the contract it gets back.
  defmodule RecordingNodeRouter do
    @moduledoc false
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      %{event | response: {:ok, %{valid: true}}}
    end
  end

  defmodule FailingNodeRouter do
    @moduledoc false
    def dispatch(%Event{} = event), do: %{event | response: {:error, :engine_unreachable}}
  end

  defmodule GarbageNodeRouter do
    @moduledoc false
    def dispatch(%Event{} = event), do: %{event | response: :who_knows}
  end

  # Inserted through the changeset rather than `Workflows.create_workflow/2` so
  # the fixture does not have to stub the `workflow.created` NodeRouter dispatch.
  # `person_id` is `Zoi.integer()` and required on `UpdatePerson`, which makes it the
  # one field in this graph whose declared type the payload can get wrong.
  defp full_payload(extra),
    do: Map.merge(%{"email topic" => "Q3", "company context content" => "ctx"}, extra)

  defp workflow_fixture(opts \\ []) do
    extra_nodes =
      if Keyword.get(opts, :person_id_node, false) do
        [
          %{
            "name" => "update_person",
            "type" => "action",
            "module" => "Zaq.Agent.Tools.People.UpdatePerson",
            "index" => 3,
            "params" => %{}
          }
        ]
      else
        []
      end

    Repo.insert!(
      Workflow.changeset(%Workflow{}, %{
        "name" => "Send Leads Email",
        "status" => "draft",
        "nodes" =>
          extra_nodes ++
            [
              %{
                "name" => "ensure_person",
                "type" => "action",
                "module" => "Zaq.Agent.Tools.People.EnsurePerson",
                "index" => 0,
                "params" => %{"platform" => "email"}
              },
              %{
                "name" => "build_history",
                "type" => "action",
                "module" => "Zaq.Agent.Tools.Accounts.History",
                "index" => 1,
                "params" => %{"query" => "a default", "search_in" => "title"}
              },
              %{
                "name" => "build_agent_context",
                "type" => "action",
                "module" => "Zaq.Agent.Tools.Workflow.Concat",
                "index" => 2,
                "params" => %{"parts" => ["{{start.company context content}}"]}
              }
            ],
        "edges" => [
          %{
            "from" => "ensure_person",
            "to" => "build_history",
            "mapping" => %{
              "query" => "start.email topic",
              "person_id" => "ensure_person.person.id"
            }
          },
          %{"from" => "build_history", "to" => "build_agent_context", "mapping" => %{}}
        ]
      })
    )
  end

  describe "run/2" do
    test "reports every payload path the workflow reads" do
      workflow = workflow_fixture()

      assert {:ok, %{required_inputs: ["company context content", "email topic"]}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "rejects a payload missing a required field" do
      workflow = workflow_fixture()

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"email topic" => "Q3"}},
                 %{}
               )

      refute result.valid
      assert result.missing_inputs == ["company context content"]
      assert result.input == %{"email topic" => "Q3"}
    end

    # A null leaf is a gap, not a value: the run would read `nil` and fail for the
    # very reason this tool is called. It reports identically to an absent key,
    # because the remediation is identical — send a value.
    test "rejects a payload whose required field is present but null" do
      workflow = workflow_fixture()

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"email topic" => "Q3", "company context content" => nil}
                 },
                 %{}
               )

      refute result.valid
      assert result.missing_inputs == ["company context content"]
      assert result.input == %{"email topic" => "Q3", "company context content" => nil}
    end

    test "a null field routes like a missing one — {:ok, _}, so an edge can branch on it" do
      workflow = workflow_fixture()

      nulled = %{"email topic" => "Q3", "company context content" => nil}
      absent = %{"email topic" => "Q3"}

      assert {:ok, %{valid: false, missing_inputs: missing}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: nulled}, %{})

      assert {:ok, %{valid: false, missing_inputs: ^missing}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: absent}, %{})
    end

    # The loop the moduledoc describes — read the shape, fill it, call again — must
    # not converge on the skeleton itself.
    test "the required_input_shape sent straight back is not valid" do
      workflow = workflow_fixture()

      assert {:ok, %{required_input_shape: shape, required_inputs: required}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})

      assert {:ok, %{valid: false, missing_inputs: ^required}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: shape}, %{})
    end

    test "the shape filled in is valid — the loop still converges" do
      workflow = workflow_fixture()

      assert {:ok, %{required_input_shape: shape}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})

      filled = Map.new(shape, fn {path, nil} -> {path, "a value"} end)

      assert {:ok, %{valid: true, missing_inputs: []}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: filled}, %{})
    end

    # A wrong-typed value is not a gap: the caller sent something, it is the wrong
    # kind of something, and the remediation is a different kind of value rather than
    # a value. It gets its own bucket so an agent can tell the two apart.
    test "reports a wrong-typed required field as invalid, not missing" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: full_payload(%{"person_id" => "42"})},
                 %{}
               )

      refute result.valid
      assert [%{path: "person_id", expected: "integer", got: "string"}] = result.invalid_inputs
      refute "person_id" in result.missing_inputs
    end

    test "a wrong-typed field still routes as {:ok, _} so a remediation edge stays reachable" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, %{valid: false}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: full_payload(%{"person_id" => "42"})},
                 %{}
               )
    end

    test "a payload can populate both buckets at once" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"email topic" => "Q3", "person_id" => "42"}
                 },
                 %{}
               )

      assert result.missing_inputs == ["company context content"]
      assert [%{path: "person_id"}] = result.invalid_inputs
    end

    test "a correctly-typed payload has both buckets empty" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, %{valid: true, missing_inputs: [], invalid_inputs: []}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: full_payload(%{"person_id" => 42})},
                 %{}
               )
    end

    test "accepts a payload supplying every required field" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: true, missing_inputs: []}} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"email topic" => "Q3", "company context content" => "ctx"}
                 },
                 %{}
               )
    end

    test "accepts differently-cased keys the way FactLookup will at run time" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: true}} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"Email_Topic" => "Q3", "Company Context Content" => "ctx"}
                 },
                 %{}
               )
    end

    test "a failing verdict is {:ok, _} so an edge can route it, never {:error, _}" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: false}} = ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "defaults input to an empty map" do
      workflow = workflow_fixture()

      assert {:ok, %{input: %{}}} = ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "reports inputs the graph cannot trace as unknown, not as required" do
      workflow = workflow_fixture()

      assert {:ok, %{unsatisfiable_inputs: []}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "returns the contract as a fillable shape, not only as paths" do
      workflow = workflow_fixture()

      assert {:ok, %{required_input_shape: shape}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})

      assert shape == %{"company context content" => nil, "email topic" => nil}
    end

    test "returns an error for an unknown workflow" do
      assert {:error, message} =
               ValidateWorkflowInput.run(%{workflow_id: Ecto.UUID.generate()}, %{})

      assert message =~ "workflow not found"
    end

    test "returns an error rather than raising for a non-uuid workflow_id" do
      assert {:error, message} = ValidateWorkflowInput.run(%{workflow_id: "not-a-uuid"}, %{})
      assert message =~ "not a valid uuid"
    end

    test "returns an error for a non-string workflow_id" do
      assert {:error, message} = ValidateWorkflowInput.run(%{workflow_id: 42}, %{})
      assert message =~ "not a valid uuid"
    end
  end

  describe "schema" do
    test "workflow_id is required and input is not" do
      fields = Map.new(ValidateWorkflowInput.schema().fields)

      assert fields[:workflow_id].meta.required
      refute fields[:input].meta.required
    end

    # `input` carrying `meta.required` would make every workflow using this action
    # as a node report a phantom `input` requirement, since
    # `InputContract.required_schema_fields/1` reads that flag. `Zoi.default/2`
    # alone does not clear it — only `Zoi.optional/1` does.
    test "the action contributes no phantom required field to a contract" do
      assert InputContract.required_schema_fields(inspect(ValidateWorkflowInput)) ==
               ["workflow_id"]
    end

    # A scalar payload must reach `run/2` and come back as an invalid verdict, not
    # be rejected at schema validation.
    test "input accepts a non-map payload" do
      assert {:ok, %{input: "not a map"}} =
               Zoi.parse(
                 ValidateWorkflowInput.schema(),
                 %{workflow_id: Ecto.UUID.generate(), input: "not a map"}
               )
    end

    test "a scalar payload is reported invalid rather than raising" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: false, input: "not a map"}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: "not a map"},
                 %{}
               )
    end

    # Only an *omitted* `input` defaults to `%{}`. A falsy payload is something the
    # agent actually sent: it has to come back as an invalid verdict on what it sent,
    # not be silently replaced and echoed as an empty map.
    test "a falsy payload is reported against the contract, not coerced to an empty map" do
      workflow = workflow_fixture()

      for payload <- [false, 0, "", nil] do
        assert {:ok, %{valid: false, input: echoed}} =
                 ValidateWorkflowInput.run(
                   %{workflow_id: workflow.id, input: payload},
                   %{}
                 )

        assert echoed === payload
      end
    end

    test "an omitted payload still defaults to an empty map" do
      workflow = workflow_fixture()

      assert {:ok, %{input: %{}}} = ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end
  end

  # The tool is agent-callable, so it may execute on the Agent node while the
  # workflow row lives on the Engine. It must reach it through a named Engine
  # action rather than reading the Repo where it happens to run.
  describe "node boundary" do
    test "dispatches a named engine action instead of reading the workflow locally" do
      id = Ecto.UUID.generate()

      assert {:ok, _contract} =
               ValidateWorkflowInput.run(
                 %{workflow_id: id, input: %{"name" => "Ada"}},
                 %{node_router: RecordingNodeRouter}
               )

      assert_received {:dispatched, %Event{} = event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :workflow_input_contract
      assert event.request == %{workflow_id: id, input: %{"name" => "Ada"}}
    end

    # Params reach an action atom-keyed from `DagBuilder` but string-keyed from a
    # direct tool call, and every sibling workflow action reads both.
    test "string-keyed params are read like atom-keyed ones" do
      id = Ecto.UUID.generate()

      assert {:ok, %{input: %{"name" => "Ada"}}} =
               ValidateWorkflowInput.run(
                 %{"workflow_id" => id, "input" => %{"name" => "Ada"}},
                 %{node_router: RecordingNodeRouter}
               )

      assert_received {:dispatched, %Event{request: %{workflow_id: ^id}}}
    end

    # A params map naming no workflow is a caller error to report, not a
    # `FunctionClauseError` that crashes the step around it.
    test "a missing workflow_id is reported rather than raised" do
      assert {:error, "workflow_id is required"} =
               ValidateWorkflowInput.run(%{input: %{}}, %{node_router: RecordingNodeRouter})
    end

    test "the echoed input comes from the caller, not from the routed response" do
      assert {:ok, %{input: %{"name" => "Ada"}}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate(), input: %{"name" => "Ada"}},
                 %{node_router: RecordingNodeRouter}
               )
    end

    test "an unreachable engine surfaces as an error, not a false verdict" do
      assert {:error, :engine_unreachable} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate()},
                 %{node_router: FailingNodeRouter}
               )
    end

    test "an unexpected response shape is reported rather than matched blindly" do
      assert {:error, message} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate()},
                 %{node_router: GarbageNodeRouter}
               )

      assert message =~ "who_knows"
    end
  end
end
