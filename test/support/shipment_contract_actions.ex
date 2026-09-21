defmodule Zaq.Engine.Workflows.Test.ShipmentActions do
  @moduledoc """
  A self-contained workflow for exercising the input contract's third level — the
  rules an author declares, not just keys and types.

  Everything the tests need lives here: three actions and the graph that wires them.
  Nothing is read from `test/support/fixtures/workflows/`, and none of these modules
  ship in `lib/`, so the suite stands on its own.

  The three actions between them cover:

    * **`ValidateShipment`** — Zoi, one of each rule Zoi can express on a scalar
      (pattern, min/max length, bounds, format, enum) plus a rule *inside* a list,
      so a failure has somewhere deeper than the top level to report from.
    * **`ScoreShipmentRisk`** — Zoi, with a structured nested object and all three
      ways a Zoi field can be optional.
    * **`DispatchShipmentNotice`** — the NimbleOptions dialect, which carries types
      and a choice set but no rules, so one graph reaches both halves of
      `Action.field_specs/1`.

  `graph/1` returns the workflow as `Workflows.import_workflow/1` takes it.
  """

  defmodule ValidateShipment do
    @moduledoc """
    Validates a shipment request against the carrier's acceptance rules.

    Every rule is declared in the schema rather than checked in `run/2`, so a bad
    payload is refused twice from one declaration: by `InputContract` before the run
    starts, and by `StepRunner` at the step itself.
    """

    use Zaq.Engine.Workflows.Action,
      name: "test_validate_shipment",
      description: "Validate a shipment request and return the routing decision for it.",
      schema:
        Zoi.object(%{
          reference_code:
            Zoi.string(description: "Carrier reference: three capitals, a hyphen, four digits")
            # `\\A` and `\\z`, not `^` and `$`: PCRE's `$` also matches before a trailing
            # newline, so `"ABC-1234\\n"` would satisfy an anchored-looking pattern.
            |> Zoi.regex(~r/\A[A-Z]{3}-\d{4}\z/),
          label:
            Zoi.string(description: "Human-readable label, 8 to 12 characters")
            |> Zoi.min(8)
            |> Zoi.max(12),
          quantity:
            Zoi.integer(description: "Units in the shipment, 1 to 500 inclusive")
            |> Zoi.gte(1)
            |> Zoi.lte(500),
          weight_kg:
            Zoi.float(description: "Total weight in kilograms, greater than zero")
            |> Zoi.gt(0),
          notify_email: Zoi.email(description: "Address notified once the shipment is accepted"),
          priority:
            Zoi.enum(["standard", "express", "overnight"], description: "Requested service level")
            |> Zoi.default("standard"),
          tags:
            Zoi.array(Zoi.string() |> Zoi.min(2), description: "Routing tags, at most five")
            |> Zoi.max(5)
            |> Zoi.default([])
        }),
      output_schema:
        Zoi.object(%{
          shipment_id: Zoi.string(description: "Identifier assigned to the accepted shipment"),
          accepted: Zoi.boolean(description: "Whether the carrier accepted the request"),
          route: Zoi.string(description: "Routing lane the shipment was placed on")
        })

    @impl Jido.Action
    def run(params, _context) do
      # A lone `{{...}}` that resolves to nothing arrives as `nil`, not as an absent
      # key, so the schema default cannot stand in for it here.
      reference = Map.get(params, :reference_code) || "UNK-0000"
      quantity = Map.get(params, :quantity) || 0
      priority = Map.get(params, :priority) || "standard"

      {:ok,
       %{
         shipment_id: "shp_" <> String.downcase(String.replace(reference, "-", "")),
         accepted: true,
         route: route_for(priority, quantity)
       }}
    end

    defp route_for("overnight", _quantity), do: "air-priority"
    defp route_for("express", quantity) when quantity > 100, do: "air-bulk"
    defp route_for("express", _quantity), do: "air-standard"
    defp route_for(_priority, quantity) when quantity > 250, do: "ground-bulk"
    defp route_for(_priority, _quantity), do: "ground-standard"
  end

  defmodule ScoreShipmentRisk do
    @moduledoc """
    Scores an accepted shipment for handling risk.

    Declares a *structured* nested field (`profile`) and all three ways a Zoi field
    can be optional: `Zoi.default/2` on `threshold`, and `Zoi.optional/1` — which
    clears `required` in place rather than wrapping — on `reviewer_email`.
    """

    use Zaq.Engine.Workflows.Action,
      name: "test_score_shipment_risk",
      description: "Score an accepted shipment for handling risk and band it.",
      schema:
        Zoi.object(%{
          shipment_id: Zoi.string(description: "Identifier from validate_shipment"),
          profile:
            Zoi.object(
              %{
                region: Zoi.enum(["emea", "amer", "apac"]) |> Zoi.default("emea"),
                fragile: Zoi.boolean() |> Zoi.default(false)
              },
              description: "Destination region and fragility of the goods"
            ),
          threshold:
            Zoi.integer(description: "Score above which the shipment is flagged, 0 to 100")
            |> Zoi.gte(0)
            |> Zoi.lte(100)
            |> Zoi.default(50),
          reviewer_email:
            Zoi.optional(Zoi.email(description: "Address to copy when the shipment is flagged"))
        }),
      output_schema:
        Zoi.object(%{
          score: Zoi.integer(description: "Handling risk score, 0 to 100"),
          band: Zoi.string(description: "Banded score: low, medium or high"),
          flagged: Zoi.boolean(description: "Whether the score exceeded the threshold"),
          detail: Zoi.map(description: "The full scoring result, for a Condition to read")
        })

    @impl Jido.Action
    def run(params, _context) do
      profile = Map.get(params, :profile) || %{}
      threshold = Map.get(params, :threshold) || 50

      score = score_for(profile)
      band = band_for(score)
      flagged = score > threshold

      detail =
        %{"score" => score, "band" => band, "flagged" => flagged}
        |> put_reviewer(flagged, Map.get(params, :reviewer_email))

      {:ok, %{score: score, band: band, flagged: flagged, detail: detail}}
    end

    # An omitted reviewer is an omission, not an empty value: nothing is added.
    defp put_reviewer(detail, true, email) when is_binary(email),
      do: Map.put(detail, "reviewer", email)

    defp put_reviewer(detail, _flagged, _email), do: detail

    defp score_for(profile) do
      base = if fetch(profile, :region) == "apac", do: 40, else: 20
      if fetch(profile, :fragile) == true, do: base + 35, else: base
    end

    defp fetch(profile, key) when is_map(profile) do
      case Zaq.Engine.Workflows.Action.fetch_param(profile, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end

    defp fetch(_profile, _key), do: nil

    defp band_for(score) when score >= 60, do: "high"
    defp band_for(score) when score >= 30, do: "medium"
    defp band_for(_score), do: "low"
  end

  defmodule DispatchShipmentNotice do
    @moduledoc """
    Sends the shipment notice on a chosen channel.

    Declared in the NimbleOptions dialect rather than Zoi, so a graph using it
    alongside `ValidateShipment` reaches both halves of `Action.field_specs/1`. The
    dialect carries types and a choice set but no length, pattern or bound.
    """

    use Zaq.Engine.Workflows.Action,
      name: "test_dispatch_shipment_notice",
      description: "Send the shipment notice to a recipient on one channel.",
      schema: [
        shipment_id: [type: :string, required: true, doc: "Identifier from validate_shipment"],
        channel: [
          type: {:in, [:email, :sms, :webhook]},
          required: true,
          doc: "Delivery channel: email, sms or webhook"
        ],
        recipient: [type: :string, required: true, doc: "Address or endpoint to notify"],
        body: [type: :string, required: true, doc: "Notice text to deliver"],
        attempts: [type: :integer, required: false, default: 1, doc: "Delivery attempts"]
      ],
      output_schema: [
        notified: [type: :boolean, required: true, doc: "Whether the notice was accepted"],
        channel_used: [type: :string, required: true, doc: "Channel the notice went out on"]
      ]

    @impl Jido.Action
    def run(params, _context) do
      channel = params |> Map.get(:channel, :email) |> to_string()

      {:ok, %{notified: true, channel_used: channel}}
    end
  end

  @doc """
  The workflow, as `Workflows.import_workflow/1` takes it.

  Pass `draft_notice:` to swap the `RunAgent` node for a stub — the real one needs an
  agent, and the graph is here to exercise the contract rather than the LLM.

  Five edges, conditions on four of them (including one on the `start` edge, which is
  what makes `channel` a payload path in its own right), mappings on three, a
  `Condition` fed its `input` by mapping rather than by a legacy dotted string, and a
  `RunAgent` whose prompt interpolates one payload path — the untyped case.
  """
  @spec graph(keyword()) :: map()
  def graph(opts \\ []) do
    draft = Keyword.get(opts, :draft_notice, "Zaq.Agent.Tools.Workflow.RunAgent")

    %{
      "name" => "Shipment Contract #{System.unique_integer([:positive])}",
      "status" => "active",
      "nodes" => [
        node(0, "validate", ValidateShipment, %{"priority" => "{{start.priority}}"}),
        node(1, "score", ScoreShipmentRisk, %{
          "threshold" => "{{start.threshold}}",
          "reviewer_email" => "{{start.reviewer_email}}"
        }),
        node(2, "risk_gate", "Zaq.Agent.Tools.Workflow.Condition", %{
          "conditions" => [%{"key" => "flagged", "op" => "eq", "value" => true}],
          "on_fail" => "continue"
        }),
        node(3, "draft_notice", draft, %{
          "agent_id" => 1,
          "input" =>
            "Draft a shipment notice for {{validate.shipment_id}} on route " <>
              "{{validate.route}}, risk band {{score.band}}, addressed to " <>
              "{{start.customer_name}}. Keep it under 80 words."
        }),
        node(4, "notify", DispatchShipmentNotice, %{})
      ],
      "edges" => [
        %{
          "from" => "start",
          "to" => "validate",
          "mapping" => %{},
          "condition" => %{"field" => "channel", "op" => "not_empty"}
        },
        %{
          "from" => "validate",
          "to" => "score",
          "mapping" => %{"shipment_id" => "validate.shipment_id", "profile" => "start.profile"},
          "condition" => %{"field" => "accepted", "op" => "eq", "value" => true}
        },
        %{"from" => "score", "to" => "risk_gate", "mapping" => %{"input" => "score.detail"}},
        %{
          "from" => "risk_gate",
          "to" => "draft_notice",
          "mapping" => %{},
          "condition" => %{"field" => "passed", "op" => "eq", "value" => true}
        },
        %{
          "from" => "draft_notice",
          "to" => "notify",
          "mapping" => %{
            "shipment_id" => "validate.shipment_id",
            "recipient" => "start.notify_email",
            "channel" => "start.channel",
            "body" => "draft_notice.output",
            "attempts" => "start.attempts"
          },
          "condition" => %{"field" => "output", "op" => "not_empty"}
        }
      ]
    }
  end

  defp node(index, name, module, params) do
    %{
      "index" => index,
      "name" => name,
      "type" => "action",
      "module" => to_string(module),
      "params" => params
    }
  end
end
