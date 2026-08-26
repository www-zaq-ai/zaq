defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInputTest do
  use Zaq.DataCase, async: true

  import Zaq.InputContractHelpers

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
      %{event | response: {:ok, %{valid?: true}}}
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

  # The verdict carries the shape as data, so a test can fill it exactly the way
  # an agent reading the result would. Probed with a payload rather than with
  # `%{}`, which is refused before any contract is derived.
  defp shape_for(workflow) do
    assert {:ok, %{required_input_shape: shape}} =
             ValidateWorkflowInput.run(
               %{workflow_id: workflow.id, input: %{"probe" => "probe"}},
               %{}
             )

    shape
  end

  # A graph whose single step needs nothing from the trigger event.
  defp triggerless_workflow_fixture do
    Repo.insert!(
      Workflow.changeset(%Workflow{}, %{
        "name" => "Nothing From Start",
        "status" => "draft",
        "nodes" => [
          %{
            "name" => "build_history",
            "type" => "action",
            "module" => "Zaq.Agent.Tools.Accounts.History",
            "index" => 0,
            "params" => %{"query" => "a default", "search_in" => "title"}
          }
        ],
        "edges" => []
      })
    )
  end

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
    # Both lists together are every path the workflow reads. `Concat.parts` is
    # required, so `company context content` must be sent; `History.query` is not,
    # so `email topic` is named but not demanded.
    # A path is optional about *presence* only. Sent with the wrong kind of value it
    # fails the verdict like any other, because the step validates it either way.
    test "an optional path supplied with the wrong kind of value is invalid" do
      workflow = workflow_fixture()

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"company context content" => "ctx", "email topic" => 42}
                 },
                 %{}
               )

      refute result.valid?
      assert missing(result) == []

      assert [
               %{
                 path: ["email topic"],
                 code: :invalid_type,
                 message: "expected string, got integer"
               }
             ] =
               result.errors
    end

    # The agent renders "what the workflow expects" from this and nothing else.
    test "an omitted optional path is not a gap" do
      workflow = workflow_fixture()

      assert {:ok, %{valid?: true, errors: []}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"company context content" => "ctx"}},
                 %{}
               )
    end

    # An empty payload carries nothing to judge, so it is refused rather than
    # answered with a verdict every path of which is missing.
    test "an empty input is refused" do
      workflow = workflow_fixture()

      assert {:error, "input is required"} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: %{}}, %{})
    end

    test "an explicitly empty, null or omitted input is refused the same way" do
      workflow = workflow_fixture()

      for params <- [
            %{workflow_id: workflow.id, input: %{}},
            %{workflow_id: workflow.id, input: nil},
            %{workflow_id: workflow.id}
          ] do
        assert {:error, "input is required"} = ValidateWorkflowInput.run(params, %{})
      end
    end

    # Everything the agent needs to ask a useful question travels as a field. None of
    # it has to be parsed back out of a message, so none of it can be lost to a
    # truncated one.
    # The skeleton names only what is owed. An optional path in it reads as another
    # gap for the agent to invent a value for.
    test "rejects a payload missing a required field" do
      workflow = workflow_fixture()

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"email topic" => "Q3"}},
                 %{}
               )

      refute result.valid?
      assert missing(result) == [["company context content"]]
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

      refute result.valid?
      assert missing(result) == [["company context content"]]
    end

    test "a null field routes like a missing one — {:ok, _}, so an edge can branch on it" do
      workflow = workflow_fixture()

      nulled = %{"email topic" => "Q3", "company context content" => nil}
      absent = %{"email topic" => "Q3"}

      assert {:ok, %{valid?: false, errors: missing}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: nulled}, %{})

      assert {:ok, %{valid?: false, errors: ^missing}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id, input: absent}, %{})
    end

    # The loop the moduledoc describes — read the shape, fill it, call again — must
    # not converge on the skeleton itself.
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

      refute result.valid?

      assert [
               %{
                 path: ["person_id"],
                 code: :invalid_type,
                 message: "expected integer, got string"
               }
             ] =
               result.errors

      refute ["person_id"] in missing(result)
    end

    test "a wrong-typed field still routes as {:ok, _} so a remediation edge stays reachable" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, %{valid?: false}} =
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

      assert missing(result) == [["company context content"]]
      assert refused(result) == [["person_id"]]
    end

    test "a correctly-typed payload has both buckets empty" do
      workflow = workflow_fixture(person_id_node: true)

      assert {:ok, %{valid?: true, errors: []}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: full_payload(%{"person_id" => 42})},
                 %{}
               )
    end

    test "accepts a payload supplying every required field" do
      workflow = workflow_fixture()

      assert {:ok, %{valid?: true, errors: []}} =
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

      assert {:ok, %{valid?: true}} =
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

      assert {:ok, %{valid?: false}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"email topic" => "Q3"}},
                 %{}
               )
    end

    # The input check comes before the workflow read, so a graph that needs nothing
    # from the trigger still refuses an empty payload rather than passing it.
    test "an empty input is refused even when the workflow reads nothing from the trigger" do
      workflow = triggerless_workflow_fixture()

      assert {:error, "input is required"} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})

      assert {:ok, %{valid?: true, errors: []}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"probe" => "probe"}},
                 %{}
               )
    end

    test "returns an error for an unknown workflow" do
      assert {:error, message} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate(), input: %{"probe" => "probe"}},
                 %{}
               )

      assert message =~ "workflow not found"
    end

    test "returns an error rather than raising for a non-uuid workflow_id" do
      assert {:error, message} =
               ValidateWorkflowInput.run(
                 %{workflow_id: "not-a-uuid", input: %{"probe" => "probe"}},
                 %{}
               )

      assert message =~ "not a valid uuid"
    end

    test "returns an error for a non-string workflow_id" do
      assert {:error, message} =
               ValidateWorkflowInput.run(
                 %{workflow_id: 42, input: %{"probe" => "probe"}},
                 %{}
               )

      assert message =~ "not a valid uuid"
    end
  end

  describe "schema" do
    test "both workflow_id and input are required" do
      fields = Map.new(ValidateWorkflowInput.schema().fields)

      assert fields[:workflow_id].meta.required
      assert fields[:input].meta.required
    end

    # A workflow using this action as a node genuinely needs an input for it, so
    # the field belongs in that workflow's own contract. It is only a phantom
    # when the action does not in fact need it.
    test "the action contributes its required fields to a contract" do
      assert InputContract.required_schema_fields(inspect(ValidateWorkflowInput)) ==
               ["input", "workflow_id"]
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

      assert {:ok, %{valid?: false}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: "not a map"},
                 %{}
               )
    end

    # An empty payload is refused; a falsy one is not empty, it is something the
    # agent actually sent. It has to come back as an invalid verdict on what it
    # sent, not be silently replaced and echoed as an empty map.
    test "a falsy payload is reported against the contract, not coerced to an empty map" do
      workflow = workflow_fixture()

      for payload <- [false, 0, ""] do
        assert {:ok, %{valid?: false} = verdict} =
                 ValidateWorkflowInput.run(
                   %{workflow_id: workflow.id, input: payload},
                   %{}
                 )

        # Judged, not swallowed: a scalar supplies no path, so every one is reported.
        assert missing(verdict) != []
      end
    end

    # An omitted key reads as an empty payload rather than crashing the step, and an
    # empty payload is refused — the caller is told what is missing, not handed a
    # verdict on something it never sent.
    test "an omitted payload is refused like an empty one" do
      workflow = workflow_fixture()

      assert {:error, "input is required"} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
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

      assert {:ok, %{valid?: _}} =
               ValidateWorkflowInput.run(
                 %{"workflow_id" => id, "input" => %{"name" => "Ada"}},
                 %{node_router: RecordingNodeRouter}
               )

      assert_received {:dispatched, %Event{request: %{workflow_id: ^id}}}
    end

    # The refusal is decided before the workflow is read, so an empty payload never
    # crosses the node boundary at all. Deriving a contract only to discard it costs a
    # round-trip to the Engine and hands back a graph description nobody asked for —
    # the thing an agent then turns into an invented payload template.
    test "an empty input never reaches the engine" do
      for params <- [
            %{workflow_id: Ecto.UUID.generate(), input: %{}},
            %{workflow_id: Ecto.UUID.generate(), input: nil},
            %{workflow_id: Ecto.UUID.generate()}
          ] do
        assert {:error, "input is required"} =
                 ValidateWorkflowInput.run(params, %{node_router: RecordingNodeRouter})

        refute_received {:dispatched, _event}
      end
    end

    # A params map naming no workflow is a caller error to report, not a
    # `FunctionClauseError` that crashes the step around it.
    test "a missing workflow_id is reported rather than raised" do
      assert {:error, "workflow_id is required"} =
               ValidateWorkflowInput.run(%{input: %{}}, %{node_router: RecordingNodeRouter})
    end

    test "the payload the caller sent is what crosses to the engine" do
      id = Ecto.UUID.generate()

      ValidateWorkflowInput.run(
        %{workflow_id: id, input: %{"name" => "Ada"}},
        %{node_router: RecordingNodeRouter}
      )

      assert_received {:dispatched,
                       %Event{request: %{workflow_id: ^id, input: %{"name" => "Ada"}}}}
    end

    test "an unreachable engine surfaces as an error, not a false verdict" do
      assert {:error, :engine_unreachable} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate(), input: %{"probe" => "probe"}},
                 %{node_router: FailingNodeRouter}
               )
    end

    test "an unexpected response shape is reported rather than matched blindly" do
      assert {:error, message} =
               ValidateWorkflowInput.run(
                 %{workflow_id: Ecto.UUID.generate(), input: %{"probe" => "probe"}},
                 %{node_router: GarbageNodeRouter}
               )

      assert message =~ "who_knows"
    end
  end
end
