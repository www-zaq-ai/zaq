defmodule Zaq.Workflows.StepTest do
  use ExUnit.Case, async: true

  alias Zaq.Workflows.Conditions.{EmailsFound, NoEmails}

  describe "Zaq.Workflows.Step behaviour" do
    test "EmailsFound exposes name/0" do
      assert is_binary(EmailsFound.name())
    end

    test "NoEmails exposes name/0" do
      assert is_binary(NoEmails.name())
    end
  end

  describe "EmailsFound.call/1" do
    test "returns true when emails list is non-empty" do
      assert EmailsFound.call(%{emails: ["msg1"]}) == true
    end

    test "returns false when emails list is empty" do
      assert EmailsFound.call(%{emails: []}) == false
    end

    test "accepts string-key map" do
      assert EmailsFound.call(%{"emails" => ["msg1"]}) == true
      assert EmailsFound.call(%{"emails" => []}) == false
    end
  end

  describe "NoEmails.call/1" do
    test "returns true when emails list is empty" do
      assert NoEmails.call(%{emails: []}) == true
    end

    test "returns false when emails list is non-empty" do
      assert NoEmails.call(%{emails: ["msg1"]}) == false
    end

    test "accepts string-key map" do
      assert NoEmails.call(%{"emails" => []}) == true
      assert NoEmails.call(%{"emails" => ["msg1"]}) == false
    end
  end

  describe "EmailsFound and NoEmails are mutually exclusive" do
    test "exactly one returns true for any input" do
      inputs = [%{emails: []}, %{emails: ["a"]}, %{emails: ["a", "b"]}]

      for input <- inputs do
        results = [EmailsFound.call(input), NoEmails.call(input)]

        assert Enum.count(results, & &1) == 1,
               "Expected exactly one true for #{inspect(input)}, got #{inspect(results)}"
      end
    end
  end
end
