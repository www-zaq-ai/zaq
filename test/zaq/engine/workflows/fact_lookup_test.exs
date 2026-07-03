defmodule Zaq.Engine.Workflows.FactLookupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "fetch/2 — format-insensitive fallback" do
    test "resolves a reference against a differently-cased stored key" do
      assert {:ok, "v"} =
               FactLookup.fetch(%{"Company Context Content" => "v"}, "company context content")
    end

    test "bridges spaces vs underscores vs hyphens" do
      assert {:ok, "u"} =
               FactLookup.fetch(%{"company_context_content" => "u"}, "company context content")

      assert {:ok, "h"} =
               FactLookup.fetch(%{"company-context-content" => "h"}, "company context content")
    end

    test "tolerates stray leading/trailing padding on the stored key" do
      assert {:ok, "pad"} =
               FactLookup.fetch(%{"company context content " => "pad"}, "company context content")
    end

    test "resolves a spaced segment inside a dotted start reference (issue #539)" do
      # Exact-match path: the spaced segment must survive dotted-path resolution.
      exact = %{__cascade__: %{"start" => %{"company context content" => "hello"}}}
      assert {:ok, "hello"} = FactLookup.fetch(exact, "start.company context content")

      # Fuzzy path: a human-authored header ("Company Context Content") still
      # resolves the lower/spaced reference through the fallback.
      fuzzy = %{__cascade__: %{"start" => %{"Company Context Content" => "hi"}}}
      assert {:ok, "hi"} = FactLookup.fetch(fuzzy, "start.company context content")
    end

    test "an exact match always wins over a fuzzy candidate" do
      fact = %{"company context" => "exact", "Company_Context" => "fuzzy"}
      assert {:ok, "exact"} = FactLookup.fetch(fact, "company context")
    end

    test "reserved internal keys never fuzzy-match" do
      # A reference that would canonicalize toward a "__cascade__"-like key must
      # not resolve it via the fuzzy path.
      assert :error = FactLookup.fetch(%{"__cascade__" => %{}}, "cascade")
    end

    test "does not bridge genuinely different words" do
      assert :error = FactLookup.fetch(%{"content" => "c"}, "file")
    end

    test "resolves normally when several canonically-equal keys hold the same value" do
      # Reference misses both keys exactly (different case), so both reach the
      # fuzzy path; identical values collapse to one, so no ambiguity.
      fact = %{"company context" => "same", "company_context" => "same"}
      assert {:ok, "same"} = FactLookup.fetch(fact, "Company Context")
    end

    test "refuses to guess (returns :error and warns) when canonically-equal keys disagree" do
      # "Company Context" matches neither key exactly, so both are fuzzy
      # candidates and their differing values make the match ambiguous.
      fact = %{"company context" => "a", "company_context" => "b"}

      log =
        capture_log(fn ->
          assert :error = FactLookup.fetch(fact, "Company Context")
        end)

      assert log =~ "ambiguous format-insensitive field lookup"
    end
  end
end
