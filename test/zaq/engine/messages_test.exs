defmodule Zaq.Engine.MessagesTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages
  alias Zaq.Engine.Messages.Incoming

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
