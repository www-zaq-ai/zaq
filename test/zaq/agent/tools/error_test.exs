defmodule Zaq.Agent.Tools.ErrorTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.Action.Error, as: ActionError
  alias Jido.Action.Error.TimeoutError
  alias Zaq.Agent.Tools.Error

  defmodule NotAnExceptionStruct do
    defstruct [:detail]
  end

  test "trace summaries remain JSON safe when the message limit splits a Unicode codepoint" do
    message = String.duplicate("é", 149) <> "€" <> String.duplicate("é", 10)
    summary = Error.trace_summary(ActionError.execution_error(message))
    assert String.valid?(summary.message)
    assert {:ok, _} = Jason.encode(summary)
    assert summary.message == String.duplicate("é", 149) <> "..."
  end

  property "trace error summaries are bounded valid JSON for Unicode messages" do
    check all(message <- string(:utf8, min_length: 1, max_length: 500), max_runs: 20) do
      summary = Error.trace_summary(ActionError.execution_error(message))
      assert String.valid?(summary.message)
      assert byte_size(summary.message) <= 303
      assert {:ok, _} = Jason.encode(summary)
    end
  end

  test "trace summaries retain only bounded messages from known Action errors" do
    for error <- [
          ActionError.execution_error("permission denied", %{secret: "PRIVATE"}),
          ActionError.validation_error("invalid document", %{value: "PRIVATE"}),
          TimeoutError.exception(
            message: "timed out",
            details: %{secret: "PRIVATE"}
          )
        ] do
      summary = Error.trace_summary(error)
      assert summary == %{type: Atom.to_string(error.__struct__), message: Error.format(error)}
      refute inspect(summary) =~ "PRIVATE"
    end

    error = ActionError.execution_error(String.duplicate("x", 500))
    assert byte_size(Error.trace_summary(error).message) <= 303
    unknown = %NotAnExceptionStruct{detail: "PRIVATE"}
    assert Error.trace_summary(unknown) == %{type: Atom.to_string(NotAnExceptionStruct)}
  end

  test "uses :message from atom-key map" do
    assert Error.format(%{message: "request failed"}) == "request failed"
  end

  test "prefers :display_message over :message for atom-key map" do
    reason = %{message: "internal", display_message: "friendly"}
    assert Error.format(reason) == "friendly"
  end

  test "uses message from string-key map" do
    assert Error.format(%{"message" => "request failed"}) == "request failed"
  end

  test "prefers display_message over message for string-key map" do
    reason = %{"message" => "internal", "display_message" => "friendly"}
    assert Error.format(reason) == "friendly"
  end

  test "formats exception structs using Exception.message/1" do
    reason = %RuntimeError{message: "runtime blew up"}
    assert Error.format(reason) == "runtime blew up"
  end

  test "falls back to inspect when Exception.message/1 raises" do
    reason = %NotAnExceptionStruct{detail: "ignored"}
    formatted = Error.format(reason)

    assert formatted =~ "NotAnExceptionStruct"
    assert formatted =~ "detail"
  end

  test "returns binaries trimmed" do
    assert Error.format("  timeout  ") == "timeout"
  end

  test "formats atoms with inspect" do
    assert Error.format(:timeout) == ":timeout"
  end

  test "formats generic terms with inspect" do
    assert Error.format({:error, %{reason: :timeout}}) == "{:error, %{reason: :timeout}}"
  end

  test "truncates messages above 300 chars and appends ellipsis" do
    long_message = String.duplicate("a", 305)
    formatted = Error.format(long_message)

    assert byte_size(formatted) == 303
    assert formatted == String.duplicate("a", 300) <> "..."
  end

  test "does not truncate messages up to 300 chars" do
    message = String.duplicate("a", 300)
    assert Error.format(message) == message
  end
end
