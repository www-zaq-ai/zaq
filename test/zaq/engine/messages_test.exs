defmodule Zaq.Engine.MessagesTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages
  alias Zaq.Engine.Messages.Incoming

  require Messages

  defp guard_accepts?(message_id) when Messages.is_present_message_id(message_id), do: true
  defp guard_accepts?(_message_id), do: false

  defp guard_path(message_id) when is_binary(message_id) and message_id != "", do: :binary
  defp guard_path(message_id) when is_integer(message_id), do: :integer
  defp guard_path(_message_id), do: :fallback

  describe "is_present_message_id/1 guard" do
    test "guard matches non-empty binary message_id" do
      assert guard_accepts?("msg-123")
      assert guard_path("msg-123") == :binary
    end

    test "guard rejects empty binary message_id" do
      refute guard_accepts?("")
      assert guard_path("") == :fallback
    end

    test "guard matches integer message_id" do
      assert guard_accepts?(0)
      assert guard_accepts?(42)
      assert guard_accepts?(-1)

      assert guard_path(0) == :integer
      assert guard_path(42) == :integer
      assert guard_path(-1) == :integer
    end

    test "guard rejects non-binary non-integer values" do
      for value <- [nil, 1.0, :id, %{}, [], true] do
        refute guard_accepts?(value)
        assert guard_path(value) == :fallback
      end
    end
  end

  test "request_key/2 prefers non-empty metadata request_id" do
    assert Messages.request_key(%{request_id: "req-1"}, "msg-1") == "req-1"
  end

  test "request_key/2 falls back to message_id when metadata request_id is blank" do
    assert Messages.request_key(%{request_id: ""}, "msg-1") == "msg-1"
  end

  test "request_key/2 accepts integer request_id" do
    assert Messages.request_key(%{request_id: 52}, "msg-1") == 52
  end

  test "request_key/1 uses incoming metadata then message_id" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :web,
      metadata: %{"request_id" => "req-a"},
      message_id: "msg-a"
    }

    assert Messages.request_key(incoming) == "req-a"

    incoming2 = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :web,
      metadata: %{request_id: ""},
      message_id: 77
    }

    assert Messages.request_key(incoming2) == 77
  end
end
