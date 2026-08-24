defmodule Zaq.Engine.Workflows.PlaceholdersTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Placeholders

  defp fact(extra \\ %{}, cascade \\ %{}),
    do: Map.put(extra, :__cascade__, cascade)

  describe "resolve/3 — key class" do
    test "a plain key substitutes" do
      assert Placeholders.resolve("Hi {{name}}", fact(%{"name" => "Ada"})) == "Hi Ada"
    end

    test "a key may carry spaces or hyphens — human-authored sheet headers" do
      f = fact(%{"company official name" => "Acme", "e-mail" => "a@b.c"})

      assert Placeholders.resolve("{{company official name}}", f) == "Acme"
      assert Placeholders.resolve("{{e-mail}}", f) == "a@b.c"
    end

    test "padding inside the braces is not part of the key" do
      assert Placeholders.resolve("{{  name  }}", fact(%{"name" => "Ada"})) == "Ada"
    end

    test "a node-qualified result and the start namespace resolve through the cascade" do
      f = fact(%{}, %{step_a: %{output: "done"}, start: %{"language" => "French"}})

      assert Placeholders.resolve("{{step_a.output}}/{{start.language}}", f) == "done/French"
    end

    test "an unresolved reference collapses to an empty string" do
      assert Placeholders.resolve("[{{nope}}]", fact()) == "[]"
    end
  end

  describe "resolve/3 — reserved keys" do
    # `__cascade__` sits at the fact root because FactLookup needs it there. It is
    # engine plumbing, so a placeholder naming it must not print the run's state.
    test "an internal `__*` key never resolves" do
      f = fact(%{}, %{step_a: %{output: "secret"}})

      assert Placeholders.resolve("[{{__cascade__}}]", f) == "[]"
    end
  end

  describe "resolve/3 — containers" do
    test "walks map values and list elements, leaving keys alone" do
      f = fact(%{"who" => "Ada"})

      assert Placeholders.resolve(%{"greet" => ["Hi {{who}}", "Bye {{who}}"]}, f) ==
               %{"greet" => ["Hi Ada", "Bye Ada"]}
    end

    test "a struct is a value, never walked into" do
      date = ~D[2026-01-01]

      assert Placeholders.resolve(date, fact()) == date
    end

    test "a non-string leaf passes through untouched" do
      assert Placeholders.resolve(%{"n" => 42, "ok" => true}, fact()) == %{
               "n" => 42,
               "ok" => true
             }
    end
  end

  describe "resolve/3 — stringifying" do
    test "an embedded placeholder renders scalars as themselves" do
      f = fact(%{"n" => 42, "f" => 1.5, "b" => true, "nil" => nil})

      assert Placeholders.resolve("{{n}}|{{f}}|{{b}}|{{nil}}", f) == "42|1.5|true|"
    end

    # `to_string/1` has no implementation for a map (it raises) and silently turns
    # a list into its binary form. Inspecting keeps an embedded reference total and
    # visibly a container.
    test "a container is inspected rather than raising" do
      f = fact(%{"m" => %{a: 1}, "l" => [1, 2, 3]})

      assert Placeholders.resolve("{{m}}", f) == "%{a: 1}"
      assert Placeholders.resolve("{{l}}", f) == "[1, 2, 3]"
    end
  end

  describe "resolve/3 — preserve_type" do
    test "a whole-string placeholder keeps the raw value" do
      f = fact(%{"rows" => [%{"a" => 1}]})

      assert Placeholders.resolve("{{rows}}", f, preserve_type: true) == [%{"a" => 1}]
    end

    test "surrounding whitespace still counts as whole-string" do
      f = fact(%{"n" => 42})

      assert Placeholders.resolve("  {{n}}  ", f, preserve_type: true) == 42
    end

    test "an embedded placeholder is stringified even under preserve_type" do
      f = fact(%{"n" => 42})

      assert Placeholders.resolve("n is {{n}}", f, preserve_type: true) == "n is 42"
    end

    test "without preserve_type a whole-string placeholder is stringified" do
      f = fact(%{"n" => 42})

      assert Placeholders.resolve("{{n}}", f) == "42"
    end
  end
end
