defmodule Zaq.Agent.Tools.Workflow.ConcatTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Concat

  describe "run/2" do
    test "joins parts with no separator by default" do
      assert {:ok, %{result: "abc"}} = Concat.run(%{parts: ["a", "b", "c"]}, %{})
    end

    test "joins parts with a custom separator" do
      assert {:ok, %{result: "x-y-z"}} =
               Concat.run(%{parts: ["x", "y", "z"], separator: "-"}, %{})
    end

    test "coerces non-string parts to strings" do
      assert {:ok, %{result: "row5"}} = Concat.run(%{parts: ["row", 5]}, %{})
    end

    test "substitutes {{key}} placeholders from atom-keyed params" do
      assert {:ok, %{result: "J5"}} =
               Concat.run(%{parts: ["{{column}}{{row}}"], column: "J", row: 5}, %{})
    end

    test "substitutes {{key}} placeholders from string-keyed params" do
      assert {:ok, %{result: "Sheet1!J5"}} =
               Concat.run(
                 %{"parts" => ["Sheet1!{{column}}{{row}}"], "column" => "J", "row" => 5},
                 %{}
               )
    end

    test "tolerates surrounding whitespace inside placeholders" do
      assert {:ok, %{result: "J5"}} =
               Concat.run(%{parts: ["{{ column }}{{ row }}"], column: "J", row: 5}, %{})
    end

    test "renders a missing placeholder as an empty string" do
      assert {:ok, %{result: "J"}} = Concat.run(%{parts: ["{{column}}{{row}}"], column: "J"}, %{})
    end

    test "renders a never-interned missing placeholder as an empty string" do
      key = "concat_missing_#{System.unique_integer([:positive])}"

      assert {:ok, %{result: ""}} = Concat.run(%{parts: ["{{#{key}}}"]}, %{})
    end

    test "does not return a matrix unless as_matrix is set" do
      assert {:ok, result} = Concat.run(%{parts: ["a"]}, %{})
      refute Map.has_key?(result, :matrix)
    end

    test "wraps the result as a 1x1 matrix when as_matrix is true" do
      assert {:ok, %{result: "3", matrix: [["3"]]}} =
               Concat.run(%{parts: ["{{value}}"], value: 3, as_matrix: true}, %{})
    end

    test "accepts as_matrix as the string \"true\"" do
      assert {:ok, %{matrix: [["3"]]}} =
               Concat.run(%{"parts" => ["{{value}}"], "value" => 3, "as_matrix" => "true"}, %{})
    end

    test "reserved keys are excluded from placeholder substitution" do
      assert {:ok, %{result: ""}} =
               Concat.run(%{parts: ["{{separator}}{{parts}}{{as_matrix}}"], separator: "-"}, %{})
    end

    test "returns an error when parts is not a list" do
      assert {:error, message} = Concat.run(%{parts: "nope"}, %{})
      assert message =~ "requires a list of parts"
    end

    test "returns an error when parts is missing" do
      assert {:error, message} = Concat.run(%{}, %{})
      assert message =~ "requires a list of parts"
    end
  end

  describe "cascade-aware placeholder resolution" do
    test "resolves a dotted start.* reference from the context cascade" do
      context = %{__cascade__: %{start: %{summary: "the summary"}}}

      assert {:ok, %{result: "the summary"}} =
               Concat.run(%{parts: ["{{start.summary}}"]}, context)
    end

    test "resolves a node-qualified reference from the context cascade" do
      context = %{__cascade__: %{build_history: %{count: 3}}}

      assert {:ok, %{result: "count=3"}} =
               Concat.run(%{parts: ["count={{build_history.count}}"]}, context)
    end

    test "local params still win for plain keys (back-compat)" do
      context = %{__cascade__: %{start: %{column: "Z"}}}

      assert {:ok, %{result: "J"}} = Concat.run(%{parts: ["{{column}}"], column: "J"}, context)
    end

    # `FactLookup` already resolves keys with spaces (human-authored sheet headers
    # like "Company Context Content"); the placeholder regex must extract them too,
    # otherwise `{{start.company context content}}` is emitted verbatim.
    test "resolves a dotted reference whose final segment contains spaces" do
      context = %{__cascade__: %{start: %{"company context content" => "ACME summary"}}}

      assert {:ok, %{result: "ctx: ACME summary"}} =
               Concat.run(%{parts: ["ctx: {{start.company context content}}"]}, context)
    end

    test "resolves a spaced-key sole placeholder nested inside a list part (list mode)" do
      context = %{__cascade__: %{start: %{"company context content" => "ACME summary"}}}

      assert {:ok, %{list: [%{"role" => "assistant", "content" => "ACME summary"}]}} =
               Concat.run(
                 %{
                   parts: [
                     [%{"role" => "assistant", "content" => "{{start.company context content}}"}]
                   ]
                 },
                 context
               )
    end
  end

  describe "sole-placeholder type preservation" do
    test "a whole-string placeholder resolving to a list yields a raw list (list mode)" do
      context = %{
        __cascade__: %{build_history: %{conversations: [%{role: "user", content: "hey"}]}}
      }

      assert {:ok, %{list: [%{role: "user", content: "hey"}]}} =
               Concat.run(%{parts: ["{{build_history.conversations}}"]}, context)
    end

    test "an embedded placeholder is still stringified" do
      context = %{__cascade__: %{build_history: %{conversations: [1, 2]}}}

      assert {:ok, %{result: result}} =
               Concat.run(%{parts: ["got: {{build_history.conversations}}"]}, context)

      assert result =~ "got: "
      refute match?(%{list: _}, result)
    end

    test "a sole placeholder resolving to a struct preserves the struct (list mode)" do
      dt = ~U[2026-07-06 12:00:00Z]
      context = %{__cascade__: %{start: %{when: dt}}}

      assert {:ok, %{list: [%{"ts" => ^dt}]}} =
               Concat.run(%{parts: [[%{"ts" => "{{start.when}}"}]]}, context)
    end
  end

  describe "list mode (auto-detected)" do
    test "builds an agent message array from a seeded turn and prior conversation" do
      context = %{
        __cascade__: %{
          start: %{summary: "You are helpful"},
          build_history: %{
            conversations: [
              %{role: "user", content: "hi"},
              %{role: "assistant", content: "yo"}
            ]
          }
        }
      }

      params = %{
        parts: [
          [%{"role" => "assistant", "content" => "{{start.summary}}"}],
          "{{build_history.conversations}}"
        ]
      }

      assert {:ok, %{list: list}} = Concat.run(params, context)

      assert list == [
               %{"role" => "assistant", "content" => "You are helpful"},
               %{role: "user", content: "hi"},
               %{role: "assistant", content: "yo"}
             ]

      refute Map.has_key?(%{list: list}, :result)
    end

    test "concatenates two literal lists in order" do
      assert {:ok, %{list: [1, 2, 3, 4]}} = Concat.run(%{parts: [[1, 2], [3, 4]]}, %{})
    end

    test "wraps a scalar part when another part is a list" do
      assert {:ok, %{list: ["header", %{a: 1}]}} =
               Concat.run(%{parts: ["header", [%{a: 1}]]}, %{})
    end

    test "deep-substitutes placeholders nested inside a list part" do
      context = %{__cascade__: %{start: %{name: "Ann"}}}

      assert {:ok, %{list: ["Hi Ann"]}} =
               Concat.run(%{parts: [["Hi {{start.name}}"]]}, context)
    end

    test "concatenating empty inner lists yields an empty list" do
      assert {:ok, %{list: []}} = Concat.run(%{parts: [[], []]}, %{})
    end

    test "does not stringify native map elements" do
      context = %{__cascade__: %{s: %{items: [%{id: 1}]}}}

      assert {:ok, %{list: [%{id: 1}, %{id: 2}]}} =
               Concat.run(%{parts: ["{{s.items}}", [%{id: 2}]]}, context)
    end
  end
end
