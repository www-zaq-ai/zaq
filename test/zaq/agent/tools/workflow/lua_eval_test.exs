defmodule Zaq.Agent.Tools.Workflow.LuaEvalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Workflow.LuaEval
  alias Zaq.Engine.Workflows.Action

  test "satisfies the workflow Action contract" do
    assert :ok = Action.validate(LuaEval)
  end

  test "normalizes nested objects and arrays from Lua" do
    code = """
    return {
      {agent_id = 42, questions = data.questions, target_range = "D2:D3"},
      {agent_id = 43, questions = data.questions, target_range = "E2:E3"}
    }
    """

    assert {:ok, %{result: result}} = evaluate(code, %{questions: ["Q1", "Q2"]})

    assert result == [
             %{"agent_id" => 42, "questions" => ["Q1", "Q2"], "target_range" => "D2:D3"},
             %{"agent_id" => 43, "questions" => ["Q1", "Q2"], "target_range" => "E2:E3"}
           ]
  end

  test "sorts numeric table keys and preserves sparse or mixed-key tables as maps" do
    assert {:ok, %{result: ["first", "second", "third"]}} =
             evaluate("return {[3] = 'third', [1] = 'first', [2] = 'second'}")

    assert {:ok, %{result: %{1 => "one", 3 => "three", "name" => "mixed"}}} =
             evaluate("return {[1] = 'one', [3] = 'three', name = 'mixed'}")
  end

  test "retains scalar values and only the first return value" do
    for {code, expected} <- [
          {"return 42, 'ignored'", 42},
          {"return 'answer'", "answer"},
          {"return false", false},
          {"return nil", nil},
          {"return {}", []}
        ] do
      assert {:ok, %{result: ^expected}} = evaluate(code)
    end
  end

  test "accepts arbitrary string keys in data without creating atoms" do
    key = "arbitrary-input-key-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:ok, %{result: %{^key => "value"}}} = evaluate("return data", %{key => "value"})
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "keeps the upstream sandbox enabled" do
    assert {:error, error} = evaluate("return os.execute('echo unexpected')")
    assert Exception.message(error) =~ "sandbox"
  end

  test "propagates invalid Lua and evaluation timeouts" do
    assert {:error, _reason} = evaluate("not valid Lua !")
    assert {:error, error} = evaluate("while true do end", %{}, eval_timeout_ms: 20)
    assert Exception.message(error) =~ ~r/timeout|timed out/i
  end

  test "validates code and evaluation timeout through Jido.Exec" do
    assert {:error, %Jido.Action.Error.InvalidInputError{}} = evaluate(42)

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             evaluate("return data", %{}, eval_timeout_ms: 0)
  end

  test "optionally exposes the current item and original request" do
    params = %{
      code: "return {agent_id = input.agent_id, range = request.target_range}",
      input: %{agent_id: 42},
      include_context: true
    }

    context = %{source_request: %{"target_range" => "D2:D3"}}

    assert {:ok, %{result: %{"agent_id" => 42, "range" => "D2:D3"}}} =
             Jido.Exec.run(LuaEval, params, context, max_retries: 0)

    assert {:ok, %{result: ["nil", "nil"]}} =
             evaluate("return {type(input), type(request)}")
  end

  test "merges named result fields as following Action params" do
    assert {:ok, %{agent_id: 42, input: "Q1", result: result}} =
             evaluate("return {agent_id = 42, input = 'Q1'}", %{}, merge_result: true)

    assert result == %{"agent_id" => 42, "input" => "Q1"}
    assert {:error, _reason} = evaluate("return {1, 2}", %{}, merge_result: true)
  end

  test "merging unknown fields does not create atoms" do
    key = "unknown-output-key-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    assert {:ok, %{^key => "value", result: %{^key => "value"}}} =
             evaluate("return data", %{key => "value"}, merge_result: true)

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  property "merged results cannot override workflow engine-control fields" do
    check all(
            key <-
              member_of(
                ~w(wrapped_module run_id step_name step_index timeout_ms __cascade__ __map_index__ __map_error__)
              ),
            max_runs: 20
          ) do
      assert {:error, _reason} = evaluate("return data", %{key => "blocked"}, merge_result: true)
    end
  end

  property "nested data retains list order and string-keyed values" do
    check all(
            values <- list_of(integer(-1_000_000..1_000_000), max_length: 20),
            label <- string(:alphanumeric, max_length: 30),
            max_runs: 30
          ) do
      data = %{"values" => values, "nested" => %{"label" => label, "enabled" => true}}
      assert {:ok, %{result: ^data}} = evaluate("return data", data)
    end
  end

  defp evaluate(code, data \\ %{}, opts \\ []) do
    Jido.Exec.run(LuaEval, Map.new([code: code, data: data] ++ opts), %{}, max_retries: 0)
  end
end
