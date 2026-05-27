defmodule Zaq.Channels.MessageFormatterTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing

  defmodule CustomFormatter do
    def as_html(text), do: "<custom>#{text}</custom>"
  end

  test "returns outgoing unchanged when format is not configured" do
    outgoing = %Outgoing{provider: :web, channel_id: "c1", body: "**hello**", metadata: %{a: 1}}

    formatted = MessageFormatter.format_outgoing(outgoing)
    assert formatted.body == outgoing.body
    assert formatted.metadata == %{a: 1}
  end

  test "formats markdown-like text when provider expects plain_text" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text})
      )

      outgoing = %Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "# Title\n- **hello** `code` [link](https://x)",
        metadata: %{request_id: "r1"}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "Title\n\nhello code link"
      assert formatted.metadata[:format] == :plain_text
      assert formatted.metadata[:request_id] == "r1"
      assert formatted.channel_id == outgoing.channel_id
      assert formatted.provider == outgoing.provider
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  test "formats markdown source to html when provider expects html" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{bridge: Zaq.Channels.WebBridge, message_format: :html})
      )

      outgoing = %Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "# Title\n\n**hello**",
        metadata: %{request_id: "r1"}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body =~ "<h1>"
      assert formatted.body =~ "Title</h1>"
      assert formatted.body =~ "<strong>hello</strong>"
      assert formatted.body =~ "\n"
      assert formatted.metadata[:format] == :html
      assert formatted.metadata[:request_id] == "r1"
      assert formatted.channel_id == outgoing.channel_id
      assert formatted.provider == outgoing.provider
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  test "uses BO markdown semantics for html output" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{bridge: Zaq.Channels.WebBridge, message_format: :html})
      )

      markdown = "line1\nline2\n\n- one\n- two\n\n[link](https://example.com)"

      outgoing = %Outgoing{
        provider: :web,
        channel_id: "c1",
        body: markdown,
        metadata: %{request_id: "r1"}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert {:ok, expected_html, _messages} =
               Earmark.as_html(markdown, escape: true, breaks: true)

      assert formatted.body == expected_html
      assert formatted.metadata[:format] == :html
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  test "clears existing format hint when formatting is a no-op" do
    outgoing = %Outgoing{
      provider: :web,
      channel_id: "c1",
      body: "hello",
      metadata: %{format: :html, request_id: "r1"}
    }

    formatted = MessageFormatter.format_outgoing(outgoing)

    refute Map.has_key?(formatted.metadata, :format)
    assert formatted.metadata[:request_id] == "r1"
  end

  test "uses custom formatter when message_formatter is configured" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{
          bridge: Zaq.Channels.WebBridge,
          message_format: :html,
          message_formatter: {CustomFormatter, :as_html}
        })
      )

      outgoing = %Outgoing{provider: :web, channel_id: "c1", body: "hello", metadata: %{a: 1}}

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "<custom>hello</custom>"
      assert formatted.metadata[:format] == :html
      assert formatted.metadata[:a] == 1
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  test "custom formatter crashes when configured function is missing" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{
          bridge: Zaq.Channels.WebBridge,
          message_format: :html,
          message_formatter: {CustomFormatter, :missing}
        })
      )

      outgoing = %Outgoing{provider: :web, channel_id: "c1", body: "hello", metadata: %{}}

      assert_raise UndefinedFunctionError, fn -> MessageFormatter.format_outgoing(outgoing) end
    after
      Application.put_env(:zaq, :channels, original)
    end
  end
end
