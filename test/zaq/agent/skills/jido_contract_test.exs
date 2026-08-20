defmodule Zaq.Agent.Skills.JidoContractTest do
  @moduledoc """
  Pins the four `jido_ai` behaviours the ZAQ skills design depends on.

  These are **not** tests of ZAQ code. They are a tripwire on the dependency: each one
  encodes a fact that, if it silently changed in an upstream sync, would break skills in
  a way no ZAQ test would otherwise catch.

  Context: ZAQ uses only Jido's *stateless* skill surface (`Spec`, `Loader`,
  `Diagnostics`, `Resources`, `Prompt`) and none of its *stateful* one (`Skill.Registry`,
  `Skill.Activation`, `Actions.Skill.LoadSkill`), whose gaps are tracked in
  agentjido/jido_ai#323.

  If one of these fails after a `mix deps.update jido_ai`, read the failure message
  before changing anything — it names the design decision that just lost its foundation.
  """

  use ExUnit.Case, async: true

  alias Jido.Agent
  alias Jido.Agent.StateOp
  alias Jido.Agent.StateOps
  alias Jido.AI.Effects
  alias Jido.AI.Effects.Policy
  alias Jido.AI.Skill
  alias Jido.AI.Skill.Loader
  alias Jido.AI.Skill.Prompt
  alias Jido.AI.Skill.Spec

  defp spec(name, description, body) do
    %Spec{name: name, description: description, body_ref: {:inline, body}}
  end

  describe "1. the stateless path: Skill.resolve/1 on a %Spec{}" do
    test "resolves without any Registry process running" do
      refute Process.whereis(Skill.Registry),
             "Skill.Registry is running — this test must prove resolve/1 does not need it"

      s = spec("calculator", "Precise arithmetic", "# Body")

      assert {:ok, ^s} = Skill.resolve(s)
    end

    test "reads the body straight off the spec, with no filesystem and no registry" do
      assert Skill.body(spec("calculator", "d", "# Instructions")) == "# Instructions"
    end
  end

  describe "2. the index: Prompt.render/2 with include_body: false" do
    # This is what ZAQ uses in place of upstream's `render_index/2`, which the pinned
    # fork does not have. It is the whole basis of progressive disclosure: if bodies
    # leak into this output, every skill's full text lands in every system prompt.
    test "renders names and descriptions but ZERO body bytes" do
      specs = [
        spec("calculator", "Precise arithmetic", "SECRET_BODY_ONE"),
        spec("weather", "Forecasts by city", "SECRET_BODY_TWO")
      ]

      rendered = Prompt.render(specs, include_body: false)

      assert rendered =~ "calculator"
      assert rendered =~ "Precise arithmetic"
      assert rendered =~ "weather"
      assert rendered =~ "Forecasts by city"

      refute rendered =~ "SECRET_BODY_ONE"
      refute rendered =~ "SECRET_BODY_TWO"
    end

    test "renders allowed_tools — this is how OAS tool scoping reaches the model" do
      s = %Spec{
        name: "calculator",
        description: "d",
        body_ref: {:inline, "b"},
        allowed_tools: ["Read", "Bash"]
      }

      assert Prompt.render([s], include_body: false) =~ "Read, Bash"
    end

    test "an empty skill list renders as \"\" — no header, no dangling separator" do
      assert Prompt.render([], include_body: false) == ""
    end

    test "the :header option is where ZAQ puts its load_skill instruction" do
      s = spec("calculator", "d", "b")

      assert Prompt.render([s], include_body: false, header: "CUSTOM HEADER") =~ "CUSTOM HEADER"
    end
  end

  describe "3. strict field validation for over-long descriptions" do
    test "a 1025-char description is rejected in strict mode" do
      long_description = String.duplicate("d", 1025)

      content = """
      ---
      name: calculator
      description: #{long_description}
      ---
      # Body
      """

      assert {:error, error} = Loader.parse(content, "inline", lenient: false)

      assert %Jido.AI.Skill.Error.Validation.InvalidField{
               field: :description,
               reason: :too_long,
               value: ^long_description
             } = error
    end

    test "a 1025-char description is still truncated in lenient mode" do
      long_description = String.duplicate("d", 1025)

      content = """
      ---
      name: calculator
      description: #{long_description}
      ---
      # Body
      """

      assert {:ok, %Spec{} = parsed} = Loader.parse(content, "inline", lenient: true)

      assert String.length(parsed.description) == 1024
      refute parsed.description == long_description
    end
  end

  # The load_skill action records activation by returning a StateOp alongside its result.
  # Two things must hold or activation becomes a silent no-op: StateOps mutate
  # agent.state, and the DEFAULT effect policy does not drop them.
  describe "4. the activation write path: an Action's StateOp reaches agent.state" do
    test "SetPath from a tool result is applied to agent.state" do
      agent = %Agent{state: %{}}
      op = %StateOp.SetPath{path: [:skill_activations, "calculator"], value: true}

      {updated, _directives} = StateOps.apply_state_ops(agent, [op])

      assert updated.state.skill_activations["calculator"] == true
    end

    test "the DEFAULT effect policy permits StateOps — nothing drops them" do
      policy = Effects.default_policy()

      for op <- [
            %StateOp.SetPath{path: [:a], value: 1},
            %StateOp.SetState{attrs: %{a: 1}}
          ] do
        assert Policy.allowed?(policy, op),
               "#{inspect(op.__struct__)} is denied by the default policy — " <>
                 "skill activation would silently no-op"
      end
    end
  end
end
