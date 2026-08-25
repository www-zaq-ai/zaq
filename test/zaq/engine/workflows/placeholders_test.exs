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

    # The spaced-key class has to survive a dot: this is one dotted reference whose
    # final segment is a sheet header, not a key that stops at the first space.
    test "a dotted key may carry spaces in its final segment" do
      f = fact(%{}, %{start: %{"company context content" => "ACME summary"}})

      assert Placeholders.resolve("ctx: {{start.company context content}}", f) ==
               "ctx: ACME summary"
    end

    # A bare key reads the fact root only, so a same-named node result can neither
    # shadow a sibling nor stand in for a missing one.
    test "a bare key reads the fact root, never the cascade" do
      assert Placeholders.resolve(
               "{{column}}",
               fact(%{"column" => "J"}, %{start: %{"column" => "Z"}})
             ) ==
               "J"

      assert Placeholders.resolve("{{row}}", fact(%{}, %{start: %{"row" => 5}})) == ""
    end

    test "a node-qualified result and the start namespace resolve through the cascade" do
      f = fact(%{}, %{step_a: %{output: "done"}, start: %{"language" => "French"}})

      assert Placeholders.resolve("{{step_a.output}}/{{start.language}}", f) == "done/French"
    end

    test "an unresolved reference collapses to an empty string" do
      assert Placeholders.resolve("[{{nope}}]", fact()) == "[]"
    end

    # `FactLookup` tries a key's atom form first. A key whose atom was never created
    # has to miss, not raise on `String.to_existing_atom/1`.
    test "a key whose atom was never interned resolves to an empty string" do
      key = "ph_never_interned_#{System.unique_integer([:positive])}"

      assert Placeholders.resolve("[{{#{key}}}]", fact()) == "[]"
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

    # A struct has no `to_string/1` and would be inspected into unusable text, so a
    # whole-string placeholder has to hand back the value itself.
    test "a whole-string placeholder keeps a struct" do
      dt = ~U[2026-07-06 12:00:00Z]

      assert Placeholders.resolve("{{when}}", fact(%{"when" => dt}), preserve_type: true) == dt
    end

    test "type preservation reaches placeholders nested in containers" do
      dt = ~U[2026-07-06 12:00:00Z]
      f = fact(%{"when" => dt, "rows" => [%{"a" => 1}]})

      assert Placeholders.resolve([%{"ts" => "{{when}}", "r" => "{{rows}}"}], f,
               preserve_type: true
             ) == [%{"ts" => dt, "r" => [%{"a" => 1}]}]
    end

    test "without preserve_type a whole-string placeholder is stringified" do
      f = fact(%{"n" => 42})

      assert Placeholders.resolve("{{n}}", f) == "42"
    end
  end

  describe "lone_reference?/1" do
    test "a string that is only a placeholder is a lone reference" do
      assert Placeholders.lone_reference?("{{n}}")
      assert Placeholders.lone_reference?("  {{ start.email topic }}  ")
    end

    test "an interpolated or repeated placeholder is not" do
      refute Placeholders.lone_reference?("n is {{n}}")
      refute Placeholders.lone_reference?("{{a}}{{b}}")
      refute Placeholders.lone_reference?("{{a}} and {{b}}")
    end

    test "a value carrying no placeholder at all is not" do
      refute Placeholders.lone_reference?("plain")
      refute Placeholders.lone_reference?("")
    end

    test "a non-binary is not — only an authored string can be one" do
      for value <- [42, nil, ["{{a}}"], %{"k" => "{{a}}"}, :atom, ~U[2026-07-06 12:00:00Z]] do
        refute Placeholders.lone_reference?(value)
      end
    end

    # The predicate exists to tell callers whether `resolve/3` hands back the raw value
    # or a string of it. If the two disagree, a caller reasoning about a param's type
    # from this predicate is reasoning about the wrong thing. Every value in the fact
    # is non-binary here, so "survived as itself" and "was stringified" are decidable.
    test "it agrees with resolve/3 about which values survive as themselves" do
      f = fact(%{"n" => 42, "rows" => [%{"a" => 1}]})

      for lone <- ["{{n}}", "  {{n}}  ", "{{rows}}"] do
        assert Placeholders.lone_reference?(lone)
        refute is_binary(Placeholders.resolve(lone, f, preserve_type: true))
      end

      for not_lone <- ["n is {{n}}", "{{n}}{{n}}", "{{n}} and {{rows}}", "plain", ""] do
        refute Placeholders.lone_reference?(not_lone)
        assert is_binary(Placeholders.resolve(not_lone, f, preserve_type: true))
      end
    end

    test "a lone reference to a string value still resolves to that exact value" do
      f = fact(%{"s" => "text"})

      assert Placeholders.lone_reference?("{{s}}")
      assert Placeholders.resolve("{{s}}", f, preserve_type: true) == "text"
    end
  end
end
