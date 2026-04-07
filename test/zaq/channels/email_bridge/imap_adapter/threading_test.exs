defmodule Zaq.Channels.EmailBridge.ImapAdapter.ThreadingTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EmailBridge.ImapAdapter.Threading

  test "prefers in_reply_to over other headers" do
    headers = %{
      "in_reply_to" => "<parent@example.com>",
      "references" => "<first@example.com> <second@example.com>",
      "message_id" => "<self@example.com>"
    }

    assert Threading.resolve_thread_id(headers) == "parent@example.com"
  end

  test "falls back to the last references message id" do
    headers = %{
      "references" => "<first@example.com> <second@example.com>",
      "message_id" => "<self@example.com>"
    }

    assert Threading.resolve_thread_id(headers) == "second@example.com"
  end

  test "falls back to message_id" do
    headers = %{"message_id" => "<self@example.com>"}

    assert Threading.resolve_thread_id(headers) == "self@example.com"
  end
end
