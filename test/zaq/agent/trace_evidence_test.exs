defmodule Zaq.Agent.TraceEvidenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Action.Error, as: ActionError
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Agent.StreamEvents
  alias Zaq.Agent.TraceEvidence
  alias Zaq.Contracts.Record

  test "legacy serialization retains exact shapes and its public wrapper" do
    value = %{
      {:tuple, :key} => :value,
      tuple: {:ok, nil, true, false},
      dates: [~U[2026-11-06 10:00:00Z], ~N[2026-11-06 10:00:00], ~D[2026-11-06], ~T[10:00:00]],
      scalar: [42, 1.5, "text"],
      struct: %ToolResult{output: :kept}
    }

    expected = %{
      "tuple" => ["ok", "nil", "true", "false"],
      "dates" => ["2026-11-06T10:00:00Z", "2026-11-06T10:00:00", "2026-11-06", "10:00:00"],
      "scalar" => [42, 1.5, "text"],
      "struct" => %{
        "__struct__" => "Elixir.ReqLLM.ToolResult",
        "content" => "nil",
        "metadata" => %{},
        "output" => "kept"
      },
      "{:tuple, :key}" => "value"
    }

    assert StreamEvents.json_safe(value) == expected
    assert TraceEvidence.json_safe(value) == expected
    serializer = Function.capture(StreamEvents, :json_safe, 1)
    assert serializer.(value) == expected
  end

  test "legacy serialization retains inspection fallbacks without becoming a sanitizer" do
    values = [self(), make_ref(), fn -> :ok end, <<1::1>>, <<255>>, %{bad: <<255>>}, %{42 => :ok}]

    for value <- values do
      assert TraceEvidence.json_safe(value) == StreamEvents.json_safe(value)
      assert Jason.encode!(TraceEvidence.json_safe(value))
    end

    assert TraceEvidence.json_safe(<<255>>) == inspect(<<255>>)
    assert TraceEvidence.json_safe(%{bad: <<255>>}) == %{"bad" => inspect(<<255>>)}
    assert TraceEvidence.json_safe(%{password: "unchanged"}) == %{"password" => "unchanged"}
  end

  property "metadata and runtime results share redaction without rewriting envelopes" do
    check all(value <- integer(), secret <- string(:alphanumeric, min_length: 1)) do
      payload = %{value: value, password: secret, provenance_ref: secret}
      result = {:ok, payload, [%{token: secret}]}

      expected =
        {:ok, %{value: value, password: "[REDACTED]", provenance_ref: "[REDACTED]"},
         [%{token: "[REDACTED]"}]}

      assert TraceEvidence.metadata(result) == expected
      assert TraceEvidence.result(result) == expected
    end
  end

  test "only runtime result evidence retains supported typed artifact bytes" do
    record = %Record{
      id: "record",
      kind: :document,
      content: "RECORD_BYTES",
      raw: %{private: "PROVIDER_RAW"},
      materialization_handle: "HANDLE",
      provenance_ref: "PROVENANCE"
    }

    part = %ContentPart{type: :file, data: "PART_BYTES", url: "PRIVATE_URL"}

    result =
      {:ok, %ToolResult{output: %{record: record, __content_parts__: [part]}, content: [part]},
       []}

    assert {:ok, metadata, []} = TraceEvidence.metadata(result)
    assert metadata.content == nil
    assert metadata.output.record.content == nil
    assert metadata.output.record.materialization_handle == "[REDACTED]"
    assert metadata.output.record.provenance_ref == "[REDACTED]"
    refute Map.has_key?(hd(metadata.output.__content_parts__), :data)
    refute Map.has_key?(hd(metadata.output.__content_parts__), :url)

    assert {:ok, %ToolResult{content: nil, output: output}, []} = TraceEvidence.result(result)
    assert %Record{content: "RECORD_BYTES", raw: %{}} = output.record
    assert [%ContentPart{data: "PART_BYTES"}] = output.__content_parts__
    refute inspect(output) =~ "PROVIDER_RAW"
  end

  test "unsafe struct details and runtime values are omitted, not inspected" do
    known = ActionError.execution_error("permission denied", %{private: "SECRET"})
    unknown = %RuntimeError{message: "SECRET"}
    value = {known, unknown, self(), make_ref(), fn -> "SECRET" end, <<255>>}
    evidence = TraceEvidence.metadata(value)
    assert elem(evidence, 0).message == "permission denied"
    assert elem(evidence, 1) == %{type: "Elixir.RuntimeError"}
    assert elem(evidence, 2) == "[runtime value omitted]"
    assert elem(evidence, 3) == "[runtime value omitted]"
    assert elem(evidence, 4) == "[runtime value omitted]"
    assert elem(evidence, 5) == "[binary omitted]"
    refute inspect(evidence) =~ "SECRET"
  end

  test "bounds are unchanged for maps, lists, nesting and strings" do
    assert TraceEvidence.metadata(Enum.to_list(1..101)) == Enum.to_list(1..100)
    assert map_size(TraceEvidence.metadata(Map.new(1..101, &{&1, &1}))) == 100
    deep = Enum.reduce(1..20, "deepest", fn _, acc -> %{child: acc} end)
    assert inspect(TraceEvidence.metadata(deep), limit: :infinity) =~ "[omitted]"
    refute inspect(TraceEvidence.metadata(deep), limit: :infinity) =~ "deepest"

    assert TraceEvidence.metadata(String.duplicate("a", 16_385)) ==
             String.duplicate("a", 16_384) <> "...[truncated]"
  end

  test "externalization preserves record-first ordering and optional nested policy" do
    record = %Record{
      id: "record",
      kind: :document,
      name: "report",
      content: Base.encode64("document"),
      attributes: %{"encoding" => "base64", "source_type" => "communication_media"}
    }

    part = %ContentPart{type: :file, data: "part", filename: "part.txt", media_type: "text/plain"}
    result = {:ok, %{record: record, __content_parts__: [part]}, [:effect]}

    for nested? <- [false, true] do
      assert {{:ok, %{record: safe}, [:effect]}, artifacts} =
               TraceEvidence.externalize(result, "call", "tool", nested?)

      assert safe.content == nil
      assert Enum.map(artifacts, & &1.content) == ["document", "part"]
      assert Enum.map(artifacts, & &1.tool_call_id) == ["call", "call"]

      if nested?,
        do: assert(Enum.all?(artifacts, &(&1.optional == true))),
        else: assert(Enum.all?(artifacts, &(not Map.has_key?(&1, :optional))))
    end

    assert elem(result, 1).record.content == record.content
  end

  test "malformed optional artifacts and unsupported envelopes retain their prior behavior" do
    record = %Record{
      id: "record",
      kind: :document,
      content: "invalid",
      attributes: %{encoding: "base64"}
    }

    assert {{:ok, %Record{content: nil}, []}, []} =
             TraceEvidence.externalize({:ok, record, []}, "call", "tool", true)

    for result <- [{:error, %{reason: :denied}, []}, {:ok, 42, []}, {:ok, %{safe: 42}, []}] do
      assert TraceEvidence.externalize(result, "call", "tool", true) == {result, []}
    end
  end
end
