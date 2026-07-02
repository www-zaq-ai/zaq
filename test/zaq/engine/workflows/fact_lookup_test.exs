defmodule Zaq.Engine.Workflows.FactLookupTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.FactLookup

  describe "fetch/2 — top-level keys" do
    test "resolves an atom-keyed top-level field" do
      assert {:ok, "CTO"} = FactLookup.fetch(%{position: "CTO"}, "position")
    end

    test "resolves a string-keyed top-level field" do
      assert {:ok, "CTO"} = FactLookup.fetch(%{"position" => "CTO"}, "position")
    end

    test "resolves an atom reference against a string-keyed map" do
      assert {:ok, "CTO"} = FactLookup.fetch(%{"position" => "CTO"}, :position)
    end

    test "absent key returns :error (distinct from a present nil/false)" do
      assert :error = FactLookup.fetch(%{other: 1}, "position")
      assert {:ok, nil} = FactLookup.fetch(%{position: nil}, "position")
      assert {:ok, false} = FactLookup.fetch(%{position: false}, "position")
    end

    test "a non-map fact returns :error" do
      assert :error = FactLookup.fetch("not a map", "position")
      assert :error = FactLookup.fetch(nil, "position")
    end

    test "a never-interned key string never raises and returns :error" do
      key = "never_seen_fact_key_#{System.unique_integer([:positive])}"
      assert :error = FactLookup.fetch(%{}, key)
    end
  end

  describe "fetch/2 — cascade-qualified paths" do
    test "resolves step.field from __cascade__ (atom step result)" do
      fact = %{__cascade__: %{"A" => %{gender: "female"}}}
      assert {:ok, "female"} = FactLookup.fetch(fact, "A.gender")
    end

    test "resolves step.field after a JSONB round-trip (string keys + string cascade key)" do
      fact = %{"__cascade__" => %{"A" => %{"gender" => "female"}}}
      assert {:ok, "female"} = FactLookup.fetch(fact, "A.gender")
    end

    test "resolves the planted start namespace" do
      fact = %{__cascade__: %{start: %{"company website" => "https://acme.com"}}}
      assert {:ok, "https://acme.com"} = FactLookup.fetch(fact, "start.company website")
    end

    test "descends a deeply nested cascade step result" do
      fact = %{__cascade__: %{"store" => %{record: %{id: %{value: 7}}}}}
      assert {:ok, 7} = FactLookup.fetch(fact, "store.record.id.value")
    end

    test "absent cascade step with no colliding root key returns :error" do
      assert :error = FactLookup.fetch(%{__cascade__: %{}}, "missing.gender")
      assert :error = FactLookup.fetch(%{}, "A.gender")
    end

    test "an intermediate scalar in the path returns :error" do
      fact = %{__cascade__: %{"A" => %{b: "not_a_map"}}}
      assert :error = FactLookup.fetch(fact, "A.b.c")
    end
  end

  describe "fetch/2 — plain-nested fallback (first segment is not a cascade step)" do
    test "descends a nested map at the fact root" do
      assert {:ok, "CTO"} =
               FactLookup.fetch(%{profile: %{"position" => "CTO"}}, "profile.position")
    end

    test "cascade step wins over a same-named root key" do
      fact = %{
        profile: %{"position" => "ROOT"},
        __cascade__: %{"profile" => %{"position" => "CASCADE"}}
      }

      assert {:ok, "CASCADE"} = FactLookup.fetch(fact, "profile.position")
    end
  end
end
