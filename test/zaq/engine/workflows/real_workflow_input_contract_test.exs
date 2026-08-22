defmodule Zaq.Engine.Workflows.RealWorkflowInputContractTest do
  @moduledoc """
  Pins the derived input contract of the two **real** production workflows against
  the trigger payload each one actually needs to reach every step.

    * **Dispatcher** — `Generate Company Context` (`28036805-2c12-4f18-a281-bda69c5c44cf`),
      exported as `generate_company_context.json`. Its last node `craft_email`
      (`DispatchEvent`, `machine: true`) fires `engine:craft_email`.
    * **Receiver** — `Send Leads Email` (`44f9d42f-c9b6-4b71-ba6c-1ce87e4facb5`),
      exported as `send_leads_email.json`, triggered by that same event.

  The `@*_input` maps below are the answer to "what must the trigger payload carry
  so no step fails". They are modelled on the payload of the real completed run
  `a011db2f-f8a1-41f6-8fb4-d08718ba1d2c`, reduced to the fields the graph actually
  reads.

  Between the two, the fixtures exercise both reference mechanisms the graph can
  state — edge mapping and `{{start.…}}` param placeholder — plus a nested path
  (`input.name`), a start-rooted edge condition, and a `DispatchEvent` whose
  declared `input` covers only two of the receiver's seven fields.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Workflow.ValidateWorkflowInput
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.UseCaseFixtures

  @fixtures_dir Path.join(__DIR__, "../../../support/fixtures/workflows")

  # ── Generate Company Context — 28036805 ─────────────────────────────────────

  # `company context content` is the branch selector: empty routes through the
  # extract/summarise cascade, non-empty dispatches `craft_email_direct` straight
  # away. Both branches read it, so the payload must carry it either way.
  @generate_company_context_input %{
    "company website" => "https://www.oilicraft.com/",
    "company official name" => "Oilicraft",
    "company context content" => "",
    "email topic" => "Instant AI label mockups for Oilicraft",
    "row_index" => 3
  }

  @generate_company_context_required [
    "company context content",
    "company official name",
    "company website",
    "email topic",
    "row_index"
  ]

  # ── Send Leads Email — 44f9d42f ─────────────────────────────────────────────

  # `email` is deliberately absent from the derived contract: `EnsurePerson`
  # declares it optional and resolves a person from `email`, `channel_id` or
  # `phone`, so which one arrives is the action's business, not the graph's. It is
  # in this payload because it is what the real run sent, not because the contract
  # demands it.
  @send_leads_email_input %{
    "email" => "lead@oilicraft.com",
    "name" => "Saraluna",
    "input" => %{"name" => "Saraluna"},
    "email topic" => "Instant AI label mockups for Oilicraft",
    "company official name" => "Oilicraft",
    "company context content" => "Oilicraft makes custom essential-oil labels.",
    "language" => "French",
    "sequence" => 0,
    "row_index" => 3
  }

  @send_leads_email_required [
    "company context content",
    "company official name",
    "email topic",
    "input.name",
    "language",
    "row_index",
    "sequence"
  ]

  # What the dispatching `craft_email` node declares, verbatim from the export.
  # Everything else the receiver needs arrived by cascade accident at run time.
  @craft_email_declared_input %{
    "email topic" => "produced topic",
    "company context content" => "built context document"
  }

  defp graph(filename),
    do: @fixtures_dir |> Path.join(filename) |> File.read!() |> Jason.decode!()

  describe "Generate Company Context (28036805) — derived contract" do
    test "reads five fields off the trigger payload" do
      g = graph("generate_company_context.json")

      assert InputContract.required_inputs(g) == @generate_company_context_required
    end

    test "every input's provenance is stated by the graph" do
      assert InputContract.unsatisfiable_inputs(graph("generate_company_context.json")) == []
    end

    test "the expected input satisfies every step" do
      g = graph("generate_company_context.json")

      assert %{valid: true, missing_inputs: []} =
               InputContract.check(g, @generate_company_context_input)
    end

    test "dropping any single field breaks the run" do
      g = graph("generate_company_context.json")

      for field <- Map.keys(@generate_company_context_input) do
        payload = Map.delete(@generate_company_context_input, field)

        assert %{valid: false, missing_inputs: [^field]} = InputContract.check(g, payload),
               "removing #{inspect(field)} should be reported missing"
      end
    end
  end

  describe "Send Leads Email (44f9d42f) — derived contract" do
    test "reads seven fields off the trigger payload, one of them nested" do
      g = graph("send_leads_email.json")

      assert InputContract.required_inputs(g) == @send_leads_email_required
    end

    test "the expected input satisfies every step" do
      g = graph("send_leads_email.json")

      assert %{valid: true, missing_inputs: []} =
               InputContract.check(g, @send_leads_email_input)
    end

    test "the nested path only resolves against a nested payload" do
      g = graph("send_leads_email.json")

      flat = @send_leads_email_input |> Map.delete("input") |> Map.put("name", "Saraluna")

      assert %{valid: false, missing_inputs: ["input.name"]} = InputContract.check(g, flat)
    end

    test "dropping any single contracted field breaks the run" do
      g = graph("send_leads_email.json")

      for field <- @send_leads_email_required do
        key = field |> String.split(".") |> hd()
        payload = Map.delete(@send_leads_email_input, key)

        assert %{valid: false} = verdict = InputContract.check(g, payload)
        assert field in verdict.missing_inputs
      end
    end
  end

  describe "the dispatch site does not declare what the receiver needs" do
    test "craft_email's declared input covers two of the receiver's seven fields" do
      g = graph("send_leads_email.json")

      assert %{
               valid: false,
               supplied: ["company context content", "email topic"],
               missing_inputs: [
                 "company official name",
                 "input.name",
                 "language",
                 "row_index",
                 "sequence"
               ]
             } = InputContract.check(g, @craft_email_declared_input)
    end

    test "the dispatcher's own contract does not mention the receiver's fields" do
      dispatcher = InputContract.required_inputs(graph("generate_company_context.json"))

      for field <- ["language", "sequence", "input.name"] do
        refute field in dispatcher
      end
    end
  end

  describe "the branch selector is contracted by the conditions, not by accident" do
    test "`company context content` survives removing the node that placeholders it" do
      g = graph("generate_company_context.json")

      # Two edges branch on `start.company context content` — empty routes through
      # the extract cascade, non-empty dispatches directly. It used to reach the
      # contract only because `craft_email_direct` also interpolates it into its
      # `input`; blanking that one param dropped the field the whole graph branches
      # on. The conditions now carry it on their own.
      conditions =
        Enum.count(g["edges"], &(&1["condition"]["field"] == "start.company context content"))

      assert conditions == 2

      stripped =
        update_in(g["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"name" => "craft_email_direct"} = node -> put_in(node["params"]["input"], %{})
            node -> node
          end)
        end)

      assert "company context content" in InputContract.required_inputs(stripped)
    end
  end

  describe "the contract stops where the action's own handling starts" do
    test "a schema-optional field is not contracted — the action handles its absence" do
      g = graph("send_leads_email.json")

      # `EnsurePerson` marks only `platform` required and resolves a person from
      # whichever of `email` / `channel_id` / `phone` it is given, so dropping
      # `email` is a question for the action, not a gap in the trigger payload.
      refute "email" in InputContract.required_inputs(g)

      assert %{valid: true, missing_inputs: []} =
               InputContract.check(g, Map.delete(@send_leads_email_input, "email"))
    end

    test "check_last_message_date's condition key is a path inside its input value" do
      g = graph("send_leads_email.json")

      # `input` is `build_history.metadata` and the key is `total.last_message_date`,
      # which `Condition` resolves *inside* that value. `total` is data the step
      # returns, not a node — so the graph owes nothing here.
      node = Enum.find(g["nodes"], &(&1["name"] == "check_last_message_date"))
      assert node["params"]["input"] == "build_history.metadata"
      assert [%{"key" => "total.last_message_date"}] = node["params"]["conditions"]

      refute MapSet.member?(InputContract.all_inputs(g), "check_last_message_date.conditions")
      assert InputContract.unsatisfiable_inputs(g) == []
    end

    test "every real workflow derives a complete contract" do
      # Nothing in the three exported graphs names a source without a producer:
      # each field is fed by a predecessor's declared output or required from the
      # payload. An empty list here is what makes a `valid: true` verdict complete.
      for file <- [
            "generate_company_context.json",
            "identify_leads_from_google_sheet.json",
            "send_leads_email.json"
          ] do
        assert InputContract.unsatisfiable_inputs(graph(file)) == [],
               "#{file} has a dangling source"
      end
    end
  end

  describe "ValidateWorkflowInput against the imported workflows" do
    setup do
      # Import emits `workflow.created` through NodeRouter; nothing here consumes it.
      Mox.stub(Zaq.NodeRouterMock, :dispatch, & &1)

      {:ok, dispatcher} = UseCaseFixtures.import_fixture("generate_company_context.json")
      {:ok, receiver} = UseCaseFixtures.import_fixture("send_leads_email.json")

      %{dispatcher: dispatcher, receiver: receiver}
    end

    test "the expected input is valid for the dispatcher", %{dispatcher: dispatcher} do
      assert {:ok, verdict} =
               ValidateWorkflowInput.run(
                 %{workflow_id: dispatcher.id, input: @generate_company_context_input},
                 %{}
               )

      assert verdict.valid
      assert verdict.missing_inputs == []
      assert verdict.required_inputs == @generate_company_context_required
      assert verdict.unsatisfiable_inputs == []
      assert verdict.input == @generate_company_context_input
    end

    test "the expected input is valid for the receiver", %{receiver: receiver} do
      assert {:ok, verdict} =
               ValidateWorkflowInput.run(
                 %{workflow_id: receiver.id, input: @send_leads_email_input},
                 %{}
               )

      assert verdict.valid
      assert verdict.missing_inputs == []
      assert verdict.required_inputs == @send_leads_email_required
    end

    test "the declared dispatch input is rejected with the gaps named", %{receiver: receiver} do
      assert {:ok, verdict} =
               ValidateWorkflowInput.run(
                 %{workflow_id: receiver.id, input: @craft_email_declared_input},
                 %{}
               )

      refute verdict.valid

      assert verdict.missing_inputs == [
               "company official name",
               "input.name",
               "language",
               "row_index",
               "sequence"
             ]
    end
  end

  describe "the shape is what the agent should build the payload from" do
    # The flat list reads `"input.name"`, and an agent handed only that sends a
    # literal key of that name. `FactLookup` cannot resolve it — the run would
    # read nil for `draft_email.name` and mail nobody — so the loop must not be
    # able to converge on it. This is the payload a real agent produced.
    @agent_flat_payload %{
      "company context content" => "Acme Corp is ",
      "company official name" => "Acme Corporation",
      "email topic" => "Request for a product demo",
      "input.name" => "John Doe",
      "language" => "en",
      "row_index" => 0,
      "sequence" => 1
    }

    test "a dotted path sent as a flat key stays invalid" do
      g = graph("send_leads_email.json")

      assert %{valid: false, missing_inputs: ["input.name"]} =
               InputContract.check(g, @agent_flat_payload)
    end

    test "the shape nests what the flat list only implies" do
      assert InputContract.required_input_shape(graph("send_leads_email.json")) == %{
               "company context content" => nil,
               "company official name" => nil,
               "email topic" => nil,
               "input" => %{"name" => nil},
               "language" => nil,
               "row_index" => nil,
               "sequence" => nil
             }
    end

    test "the same payload rebuilt from the shape validates" do
      g = graph("send_leads_email.json")

      {name, rest} = Map.pop(@agent_flat_payload, "input.name")
      rebuilt = Map.put(rest, "input", %{"name" => name})

      assert %{valid: true, missing_inputs: []} = InputContract.check(g, rebuilt)
    end

    test "the dispatcher's shape is flat — it has no nested path" do
      shape = InputContract.required_input_shape(graph("generate_company_context.json"))

      assert Map.keys(shape) |> Enum.sort() == @generate_company_context_required
      assert Enum.all?(Map.values(shape), &is_nil/1)
    end
  end
end
