defmodule Zaq.Utils.MapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Utils.Map

  describe "read_any/2" do
    test "returns the first present key even when the value is false" do
      assert Map.read_any(%{"include_shared" => false}, [:include_shared, "include_shared"]) ==
               false

      assert Map.read_any(%{include_shared: false}, [:include_shared, "include_shared"]) == false
    end

    test "preserves other falsey values from present keys" do
      assert Map.read_any(%{count: 0}, [:count]) == 0
      assert Map.read_any(%{items: []}, [:items]) == []
      assert Map.read_any(%{label: ""}, [:label]) == ""
    end

    test "returns nil only when none of the requested keys exists" do
      assert Map.read_any(%{"include_shared" => false}, [:missing, "other_missing"]) == nil
    end

    test "returns nil when map argument is invalid" do
      assert Map.read_any("not-a-map", [:subject, "subject"]) == nil
    end

    test "returns nil when keys argument is not a list" do
      assert Map.read_any(%{subject: "hello"}, :subject) == nil
    end
  end

  describe "read_present/2" do
    test "returns nil when inputs are invalid" do
      assert Map.read_present("not-a-map", [:subject]) == nil
      assert Map.read_present(%{subject: "hello"}, :subject) == nil
    end
  end

  describe "metadata_value/2" do
    test "reads either string or existing atom keys" do
      assert Map.metadata_value(%{"subject" => "string"}, "subject") == "string"
      assert Map.metadata_value(%{subject: "atom"}, "subject") == "atom"
      assert Map.metadata_value(%{"subject" => "string"}, :subject) == "string"
      assert Map.metadata_value(%{subject: "atom"}, :subject) == "atom"
    end

    test "returns nil for unknown atom keys without creating atoms" do
      assert Map.metadata_value(%{}, "not_existing_metadata_key") == nil
    end

    test "returns nil for invalid metadata or unsupported key types" do
      assert Map.metadata_value(nil, "subject") == nil
      assert Map.metadata_value("not-a-map", :subject) == nil
      assert Map.metadata_value(%{subject: "hello"}, nil) == nil
      assert Map.metadata_value(%{subject: "hello"}, 123) == nil
    end
  end

  describe "stringify_keys/1" do
    test "converts atom keys to strings and leaves values untouched" do
      assert Map.stringify_keys(%{:originator => "zaqos", "scope" => "openid"}) == %{
               "originator" => "zaqos",
               "scope" => "openid"
             }
    end

    property "is idempotent for atom and string keyed maps" do
      check all(
              key <-
                one_of([
                  member_of([:originator, :scope, :audience]),
                  string(:alphanumeric, min_length: 1)
                ]),
              value <- string(:printable)
            ) do
        map = %{key => value}

        assert Map.stringify_keys(Map.stringify_keys(map)) == Map.stringify_keys(map)
      end
    end
  end

  describe "metadata_subject/1" do
    test "returns nil for non-map string input" do
      assert Map.metadata_subject("not-a-map") == nil
    end

    test "returns nil for nil input" do
      assert Map.metadata_subject(nil) == nil
    end
  end
end
