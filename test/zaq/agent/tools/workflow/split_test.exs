defmodule Zaq.Agent.Tools.Workflow.SplitTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Split

  describe "run/2 — generic splitting" do
    test "splits on the first occurrence only" do
      assert {:ok, %{before: "a", after: "b=c"}} =
               Split.run(%{text: "a=b=c", separator: "="}, %{})
    end

    test "trims both sides" do
      assert {:ok, %{before: "key", after: "value"}} =
               Split.run(%{text: "  key  :   value  ", separator: ":"}, %{})
    end

    test "returns the whole text as before and empty after when separator is absent" do
      assert {:ok, %{before: "no separator here", after: ""}} =
               Split.run(%{text: "no separator here", separator: "|"}, %{})
    end

    test "handles a multi-character separator" do
      assert {:ok, %{before: "head", after: "tail"}} =
               Split.run(%{text: "head<sep>tail", separator: "<sep>"}, %{})
    end

    test "empty separator yields the whole text as before" do
      assert {:ok, %{before: "abc", after: ""}} = Split.run(%{text: "abc", separator: ""}, %{})
    end

    test "empty text yields empty before and after" do
      assert {:ok, %{before: "", after: ""}} = Split.run(%{text: "", separator: "\n"}, %{})
    end

    test "accepts string-keyed params (JSONB-rehydrated shape)" do
      assert {:ok, %{before: "x", after: "y"}} =
               Split.run(%{"text" => "x\ny", "separator" => "\n"}, %{})
    end
  end

  describe "run/2 — the email use case (subject on first line, body after)" do
    test "splits a drafted email on the first newline into subject and body" do
      draft =
        "Cut support tickets while keeping Acme's promise\n\nHi Sam, I noticed ...\n\nJulien, ZAQ"

      assert {:ok, %{before: subject, after: body}} =
               Split.run(%{text: draft, separator: "\n"}, %{})

      assert subject == "Cut support tickets while keeping Acme's promise"
      assert body == "Hi Sam, I noticed ...\n\nJulien, ZAQ"
      # The body keeps its own paragraph breaks (only the FIRST newline is the split).
      assert body =~ "\n\n"
    end
  end
end
