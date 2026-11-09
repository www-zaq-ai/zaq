defmodule Zaq.Engine.Workflows.IdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Runic.Workflow.Fact
  alias Zaq.Contracts.Record

  test "dates and naive datetimes retain their types and full identity" do
    for value <- [~D[2026-11-01], ~N[2026-11-01 10:00:00.123456]] do
      fact = Fact.new(value: %{due: value})
      assert fact.value === %{due: value}
      assert Fact.new(value: %{due: value}).payload_digest == fact.payload_digest

      changed = %{value | day: 2}
      refute Fact.new(value: %{due: changed}).payload_digest == fact.payload_digest
    end
  end

  test "nested records and timestamps retain their original runtime values" do
    record = %Record{
      id: "file-1",
      kind: :file,
      content: "hello",
      modified_at: ~U[2026-11-07 12:00:00.123456Z],
      raw: %{revision: 2}
    }

    input = %{rows: [record], messages: [%{timestamp: record.modified_at}]}
    fact = Fact.new(value: input)

    assert fact.value === input
    assert %Record{} = hd(fact.value.rows)
    assert %DateTime{} = hd(fact.value.messages).timestamp
    assert Fact.new(value: input).payload_digest == fact.payload_digest
  end

  property "record identity is deterministic and includes content and provider data" do
    check all(content <- string(:alphanumeric), revision <- integer()) do
      record = %Record{id: "stable-id", kind: :file, content: content, raw: %{revision: revision}}
      digest = Fact.new(value: record).payload_digest

      assert Fact.new(value: record).payload_digest == digest
      refute Fact.new(value: %{record | content: content <> "!"}).payload_digest == digest
      refute Fact.new(value: %{record | raw: %{revision: revision + 1}}).payload_digest == digest
    end
  end

  property "timestamp identity changes when the timestamp changes" do
    check all(seconds <- integer(0..1_000_000), delta <- integer(1..10_000)) do
      timestamp = DateTime.add(~U[2026-01-01 00:00:00Z], seconds)
      changed = DateTime.add(timestamp, delta)

      refute Fact.new(value: timestamp).payload_digest == Fact.new(value: changed).payload_digest
    end
  end

  test "nonportable nested record fields are rejected instead of omitted from identity" do
    record = %Record{id: "file-1", kind: :file, raw: %{process: self()}}

    assert_raise Runic.Identity.CanonicalError, fn -> Fact.new(value: record) end
  end
end
