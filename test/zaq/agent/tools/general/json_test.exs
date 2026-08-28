defmodule Zaq.Agent.Tools.General.JsonTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.General.DecodeJson
  alias Zaq.Agent.Tools.General.EncodeJson
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Workflows.Action

  defp encode(params) do
    with {:ok, validated} <- EncodeJson.validate_params(params) do
      EncodeJson.run(validated, %{})
    end
  end

  defp decode(params) do
    with {:ok, validated} <- DecodeJson.validate_params(params) do
      DecodeJson.run(validated, %{})
    end
  end

  test "both satisfy the workflow action contract" do
    assert :ok = Action.validate(EncodeJson)
    assert :ok = Action.validate(DecodeJson)
  end

  test "both are registered in the tool registry" do
    assert {:ok, [EncodeJson]} = Registry.resolve_modules(["general.encode_json"])
    assert {:ok, [DecodeJson]} = Registry.resolve_modules(["general.decode_json"])
  end

  describe "encoding" do
    test "encodes an object compactly by default" do
      assert {:ok, %{encoded: ~s({"a":1})}} = encode(%{data: %{"a" => 1}})
    end

    test "encodes indented when pretty is true" do
      assert {:ok, %{encoded: encoded}} = encode(%{data: %{"a" => 1}, pretty: true})

      assert encoded == "{\n  \"a\": 1\n}"
    end

    test "encodes every top-level type" do
      assert {:ok, %{encoded: "[1,2]"}} = encode(%{data: [1, 2]})
      assert {:ok, %{encoded: ~s("hi")}} = encode(%{data: "hi"})
      assert {:ok, %{encoded: "5"}} = encode(%{data: 5})
      assert {:ok, %{encoded: "true"}} = encode(%{data: true})
      assert {:ok, %{encoded: "null"}} = encode(%{data: nil})
    end

    test "returns an error for a value JSON cannot represent" do
      assert {:error, message} = EncodeJson.run(%{data: <<0xFF, 0xFE>>, pretty: false}, %{})
      assert message =~ "could not encode as JSON"

      assert {:error, message} = EncodeJson.run(%{data: {:a, :b}, pretty: false}, %{})
      assert message =~ "could not encode as JSON"
    end

    test "requires data and rejects a non-boolean pretty" do
      assert {:error, _} = EncodeJson.validate_params(%{})
      assert {:error, _} = EncodeJson.validate_params(%{data: %{}, pretty: "yes"})
    end
  end

  describe "decoding" do
    test "decodes an object" do
      assert {:ok, %{decoded: %{"a" => 1, "b" => 2}}} = decode(%{data: ~s({"a":1,"b":2})})
    end

    test "decodes an array" do
      assert {:ok, %{decoded: [1, 2, 3]}} = decode(%{data: "[1,2,3]"})
    end

    test "decodes every scalar top-level value" do
      for {json, value} <- [
            {~s("hi"), "hi"},
            {"5", 5},
            {"1.5", 1.5},
            {"true", true},
            {"false", false},
            {"null", nil}
          ] do
        assert {:ok, %{decoded: ^value}} = decode(%{data: json}), "wrong value for #{json}"
      end
    end

    test "ignores surrounding whitespace and line breaks" do
      assert {:ok, %{decoded: %{"a" => 1}}} = decode(%{data: "  {\"a\": 1}\n"})
      assert {:ok, %{decoded: %{"a" => 1}}} = decode(%{data: "{\n  \"a\": 1\n}"})
    end

    test "strips a wrapping markdown code fence" do
      assert {:ok, %{decoded: %{"a" => 1}}} = decode(%{data: "```json\n{\"a\": 1}\n```"})
      assert {:ok, %{decoded: %{"a" => 1}}} = decode(%{data: "```\n{\"a\": 1}\n```"})
      assert {:ok, %{decoded: [1, 2]}} = decode(%{data: "  ```json\n[1, 2]\n```  "})
    end

    test "leaves a fence inside a string value alone" do
      assert {:ok, result} = decode(%{data: ~s({"a":"```json"})})

      assert result.decoded == %{"a" => "```json"}
    end

    test "decodes nested structures" do
      json = ~s({"items":[{"id":1},{"id":2}],"meta":{"total":2}})

      assert {:ok, result} = decode(%{data: json})

      assert result.decoded == %{
               "items" => [%{"id" => 1}, %{"id" => 2}],
               "meta" => %{"total" => 2}
             }
    end

    test "reports where malformed JSON broke" do
      assert {:error, message} = decode(%{data: ~s({"a": })})
      assert message =~ "not valid JSON"

      assert {:error, message} = decode(%{data: "not json at all"})
      assert message =~ "not valid JSON"

      assert {:error, _} = decode(%{data: ""})
    end

    test "requires a string data parameter" do
      assert {:error, _} = DecodeJson.validate_params(%{})
      assert {:error, _} = DecodeJson.validate_params(%{data: %{"a" => 1}})
    end
  end

  describe "round trip" do
    test "every top-level type survives encode then decode" do
      values = [
        %{"a" => 1, "b" => [1, 2, %{"c" => nil}]},
        [1, "two", true, nil],
        "héllo → wörld",
        0,
        -1.5,
        true,
        false,
        nil,
        %{},
        []
      ]

      for value <- values, pretty <- [true, false] do
        assert {:ok, %{encoded: encoded}} = encode(%{data: value, pretty: pretty})

        assert {:ok, %{decoded: ^value}} = decode(%{data: encoded}),
               "round trip failed for #{inspect(value)} (pretty: #{pretty})"
      end
    end

    test "a pretty-printed payload survives a markdown fence on the way back" do
      assert {:ok, %{encoded: encoded}} = encode(%{data: %{"a" => [1, 2]}, pretty: true})

      assert {:ok, %{decoded: %{"a" => [1, 2]}}} =
               decode(%{data: "```json\n" <> encoded <> "\n```"})
    end
  end
end
