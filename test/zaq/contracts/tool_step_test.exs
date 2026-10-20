defmodule Zaq.Contracts.ToolStepTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.ToolStep

  test "one public projector orders canonical facts and excludes private bookkeeping" do
    calls = [
      %{
        "id" => "event-b",
        "invocation_id" => "b",
        "name" => "search",
        "sequence" => 2,
        "outcome" => "failed",
        "duration_ms" => 10,
        "response" => "private",
        "arguments" => "private"
      },
      %{
        "id" => "event-a",
        "invocation_id" => "a",
        "name" => "search",
        "sequence" => 1,
        "outcome" => "succeeded",
        "credentials" => "private"
      },
      %{"id" => "legacy-event", "sequence" => 3, "outcome" => "unknown"}
    ]

    assert [
             %{"id" => "a", "state" => "succeeded", "sequence" => 1},
             %{"id" => "b", "state" => "failed", "sequence" => 2, "duration_ms" => 10}
           ] = ToolStep.project(calls)

    refute Jason.encode!(ToolStep.project(calls)) =~ "private"
    assert ToolStep.project(nil) == []

    assert ToolStep.project([
             nil,
             %{},
             %{"invocation_id" => "a", "sequence" => 1, "outcome" => "invalid"}
           ]) == []
  end

  test "invalid optional duration does not erase otherwise valid invocation facts" do
    for duration <- [nil, -1, 1.5, "12"] do
      call = %{
        "invocation_id" => "a",
        "name" => "search",
        "sequence" => 1,
        "outcome" => "failed",
        "duration_ms" => duration
      }

      assert [%{"id" => "a", "state" => "failed"} = step] = ToolStep.project([call])
      refute Map.has_key?(step, "duration_ms")
    end
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        id: "call-1",
        kind: "tool",
        name: "search",
        label: "search",
        sequence: 1,
        state: "running"
      },
      overrides
    )
  end

  test "validates each state and explicitly excludes private and correlation fields" do
    for state <- ~w(running succeeded failed unknown) do
      input =
        attrs(%{
          state: state,
          arguments: %{secret: "value"},
          response: "private",
          error: "private",
          request_id: "request",
          artifacts: ["bytes"]
        })

      assert {:ok, step} = ToolStep.new(input)
      assert Enum.sort(Map.keys(step)) == ~w(id kind label name sequence state)
      assert step["state"] == state
      assert Jason.decode!(Jason.encode!(step)) == step
    end
  end

  test "rejects invalid identity, sequence, kind and states rather than inventing facts" do
    for id <- [nil, "", "  ", 12, String.duplicate("a", 257), <<255>>] do
      assert {:error, :invalid_id} = ToolStep.new(attrs(%{id: id}))
    end

    for sequence <- [nil, 0, -1, 1.0, "1"] do
      assert {:error, :invalid_sequence} = ToolStep.new(attrs(%{sequence: sequence}))
    end

    assert {:error, :invalid_kind} = ToolStep.new(attrs(%{kind: "llm"}))
    assert {:error, :invalid_state} = ToolStep.new(attrs(%{state: "interrupted"}))
    assert {:error, :invalid_state} = ToolStep.new(attrs(%{state: nil}))
    assert {:error, :invalid_step} = ToolStep.new(nil)
  end

  test "duration is optional and must be a nonnegative integer" do
    for duration <- [0, 12] do
      assert {:ok, %{"duration_ms" => ^duration}} = ToolStep.new(attrs(%{duration_ms: duration}))
    end

    assert {:ok, step} = ToolStep.new(attrs(%{duration_ms: nil}))
    refute Map.has_key?(step, "duration_ms")

    for duration <- [-1, "5", 1.5] do
      assert {:error, :invalid_duration} = ToolStep.new(attrs(%{duration_ms: duration}))
    end
  end

  test "bounds display strings on UTF-8 boundaries without truncating identity" do
    assert {:ok, step} =
             ToolStep.new(
               attrs(%{
                 id: String.duplicate("a", 256),
                 name: String.duplicate("界", 100),
                 label: String.duplicate("é", 200)
               })
             )

    assert byte_size(step["id"]) == 256
    assert byte_size(step["name"]) <= 256
    assert byte_size(step["label"]) <= 256
    assert String.valid?(step["name"])
    assert String.valid?(step["label"])

    assert {:ok, %{"name" => "tool", "label" => "tool"}} =
             ToolStep.new(attrs(%{name: nil, label: <<255>>}))
  end

  property "normalization is idempotent and identity stays unchanged" do
    check all(
            id <- string(:alphanumeric, min_length: 1, max_length: 256),
            name <- string(:utf8, max_length: 300),
            sequence <- positive_integer(),
            state <- member_of(~w(running succeeded failed unknown))
          ) do
      assert {:ok, step} =
               ToolStep.new(
                 attrs(%{
                   id: id,
                   name: name,
                   sequence: sequence,
                   state: state,
                   credentials: "never public"
                 })
               )

      assert step["id"] == id
      assert byte_size(step["name"]) <= 256
      assert String.valid?(step["name"])
      assert {:ok, ^step} = ToolStep.new(step)
      refute Map.has_key?(step, "credentials")
    end
  end
end
