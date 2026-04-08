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

  test "resolve_thread_key prefers first references message id" do
    headers = %{
      "in_reply_to" => "<parent@example.com>",
      "references" => "<root@example.com> <parent@example.com>",
      "message_id" => "<self@example.com>"
    }

    assert Threading.resolve_thread_key(headers) == "root@example.com"
  end

  test "resolve_thread_key falls back to in_reply_to then message_id" do
    assert Threading.resolve_thread_key(%{"in_reply_to" => "<parent@example.com>"}) ==
             "parent@example.com"

    assert Threading.resolve_thread_key(%{"message_id" => "<self@example.com>"}) ==
             "self@example.com"
  end

  test "references parsing accepts linear whitespace separators" do
    headers = %{"references" => "<first@example.com>\t<second@example.com>"}

    assert Threading.resolve_thread_key(headers) == "first@example.com"
    assert Threading.resolve_thread_id(headers) == "second@example.com"
  end
end
