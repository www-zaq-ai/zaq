defmodule Zaq.Agent.Tools.Workflow.LuaEvalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Workflow.LuaEval
  alias Zaq.Engine.Workflows.Action

  setup_all do
    # Lua loads its compiler and shared sandbox template lazily. Prepare them
    # before the per-evaluation deadline used by the conversion assertions.
    assert {[true], _lua} = Lua.eval!(Lua.new(), "return true")
    :ok
  end

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

  test "supports explicit first and list return modes" do
    code = "return {answer = 42}, {1, 2}, false, nil, 'last'"

    assert evaluate(code, %{}, return_mode: :first) == {:ok, %{result: %{"answer" => 42}}}

    assert evaluate(code, %{}, return_mode: :list) ==
             {:ok, %{result: [%{"answer" => 42}, [1, 2], false, nil, "last"]}}

    assert evaluate("return", %{}, return_mode: :list) == {:ok, %{result: [nil]}}
    assert evaluate("return {}", %{}, return_mode: :list) == {:ok, %{result: [[]]}}
  end

  test "rejects unsupported return modes through Jido.Exec" do
    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             evaluate("return 42", %{}, return_mode: :invalid)
  end

  test "accepts JSON string return modes through Jido.Exec" do
    assert evaluate("return 10, 20", %{}, return_mode: "first") == {:ok, %{result: 10}}
    assert evaluate("return 10, 20", %{}, return_mode: "list") == {:ok, %{result: [10, 20]}}
  end

  test "rejects unsupported string return modes through Jido.Exec" do
    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             evaluate("return 42", %{}, return_mode: "invalid")
  end

  test "keeps the upstream sandbox enabled" do
    assert {:error, error} = evaluate("return os.execute('echo unexpected')")
    assert Exception.message(error) =~ "sandbox"
  end

  test "returns upstream errors for unsupported input values, including nested data" do
    for value <- [self(), make_ref(), {:unsupported, 42, 7}, ~U[2026-01-01 00:00:00Z]],
        data <- [value, %{"nested" => [value]}] do
      assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} =
               evaluate("return data", data)

      assert Exception.message(error) =~ ~r/(Failed to encode|cannot encode)/
      assert error.details.type == :lua_error
    end
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

  test "reads context only from explicit data without injecting globals or loading a run" do
    params = %{
      code: "return {agent_id = data.item.agent_id, range = data.job.target_range}",
      data: %{item: %{agent_id: 42}, job: %{target_range: "D2:D3"}}
    }

    context = %{run_id: "not-a-persisted-run", source_request: %{"target_range" => "wrong"}}

    assert {:ok, %{result: %{"agent_id" => 42, "range" => "D2:D3"}}} =
             Jido.Exec.run(LuaEval, params, context, max_retries: 0)

    assert {:ok, %{result: ["nil", "nil"]}} =
             Jido.Exec.run(LuaEval, %{code: "return {type(input), type(request)}"}, context,
               max_retries: 0
             )
  end

  test "keeps named fields and lists under result for cascade mappings" do
    assert evaluate("return {agent_id = 42, input = 'Q1'}") ==
             {:ok, %{result: %{"agent_id" => 42, "input" => "Q1"}}}

    assert evaluate("return {1, 2}") == {:ok, %{result: [1, 2]}}
  end

  test "returning unknown fields does not create atoms" do
    key = "unknown-output-key-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    assert evaluate("return data", %{key => "value"}) ==
             {:ok, %{result: %{key => "value"}}}

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  property "returned data cannot override workflow engine-control fields" do
    check all(
            key <-
              member_of(
                ~w(wrapped_module run_id step_name step_index timeout_ms __cascade__ __map_index__ __map_error__)
              ),
            max_runs: 20
          ) do
      assert evaluate("return data", %{key => "nested"}) ==
               {:ok, %{result: %{key => "nested"}}}
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

  property "list return mode normalizes each value without flattening returned tables" do
    check all(
            values <- list_of(integer(-1_000_000..1_000_000), max_length: 20),
            label <- string(:alphanumeric, max_length: 30),
            max_runs: 30
          ) do
      data = %{"values" => values, "label" => label}

      assert evaluate("return data.values, data.label", data, return_mode: :list) ==
               {:ok, %{result: [values, label]}}
    end
  end

  defp evaluate(code, data \\ %{}, opts \\ []) do
    Jido.Exec.run(LuaEval, Map.new([code: code, data: data] ++ opts), %{}, max_retries: 0)
  end
end
