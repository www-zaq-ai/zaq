defmodule Zaq.Agent.Tools.ErrorTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Error

  defmodule NotAnExceptionStruct do
    defstruct [:detail]
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

  # Ecto.Changeset is not an Exception, so without a dedicated clause it would
  # fall through to a raw `#Ecto.Changeset<...>` struct dump — unreadable in the
  # BO run view. Field errors must render as plain prose instead.
  test "formats an Ecto.Changeset's errors as readable prose, not a struct dump" do
    changeset =
      {%{}, %{channel_identifier: :string, platform: :string}}
      |> Ecto.Changeset.cast(%{}, [:channel_identifier, :platform])
      |> Ecto.Changeset.validate_required([:channel_identifier, :platform])

    formatted = Error.format(changeset)

    assert formatted =~ "channel_identifier"
    assert formatted =~ "can't be blank"
    refute formatted =~ "#Ecto.Changeset"
    refute formatted =~ "%Ecto.Changeset"
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
