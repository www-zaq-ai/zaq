defmodule Zaq.Channels.MessageFormatterTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing

  defmodule CustomFormatter do
    def as_html(text), do: "<custom>#{text}</custom>"
    def raise_error(_text), do: raise("boom")
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

  test "custom formatter falls back when configured function is missing" do
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

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "hello"
      assert formatted.metadata[:format] == :html
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  test "custom formatter falls back when configured function raises" do
    original = Application.get_env(:zaq, :channels)

    try do
      Application.put_env(
        :zaq,
        :channels,
        Map.put(original, :web, %{
          bridge: Zaq.Channels.WebBridge,
          message_format: :html,
          message_formatter: {CustomFormatter, :raise_error}
        })
      )

      outgoing = %Outgoing{provider: :web, channel_id: "c1", body: "hello", metadata: %{a: 1}}

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "hello"
      assert formatted.metadata[:format] == :html
      assert formatted.metadata[:a] == 1
    after
      Application.put_env(:zaq, :channels, original)
    end
  end

  describe "coverage gaps" do
    test "A: non-binary body passthrough and metadata fallback" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          Map.put(original, :web, %{bridge: Zaq.Channels.WebBridge, message_format: :html})
        )

        outgoing = %Outgoing{provider: :web, body: %{raw: "x"}, metadata: nil, channel_id: "c1"}

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == %{raw: "x"}
        assert formatted.metadata == %{format: :html}
        assert formatted.provider == outgoing.provider
        assert formatted.channel_id == outgoing.channel_id
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "B: binary provider and existing atom format from string" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          Map.put(original, :web, %{bridge: Zaq.Channels.WebBridge, message_format: "html"})
        )

        outgoing = %Outgoing{
          provider: "web",
          channel_id: "c1",
          body: "# T",
          metadata: %{request_id: "r1"}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body =~ "<h1>"
        assert formatted.body =~ "T</h1>"
        assert formatted.metadata[:format] == :html
        assert formatted.metadata[:request_id] == "r1"
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "C: unsupported provider type and no-op format cleanup" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(:zaq, :channels, original)

        outgoing = %Outgoing{
          provider: 1234,
          channel_id: "c1",
          body: "hello",
          metadata: %{"format" => "legacy", keep: 1, format: :html}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "hello"
        refute Map.has_key?(formatted.metadata, :format)
        refute Map.has_key?(formatted.metadata, "format")
        assert formatted.metadata.keep == 1
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "D: provider config not a map" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(:zaq, :channels, %{web: 123})

        outgoing = %Outgoing{provider: :web, channel_id: "c1", body: "hello", metadata: %{a: 1}}

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "hello"
        refute Map.has_key?(formatted.metadata, :format)
        refute Map.has_key?(formatted.metadata, "format")
        assert formatted.metadata.a == 1
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "E: unknown binary format string is rescued to nil" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          %{
            web: %{bridge: Zaq.Channels.WebBridge, message_format: "definitely_not_existing_atom"}
          }
        )

        outgoing = %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: "# Title",
          metadata: %{request_id: "r1"}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "# Title"
        refute Map.has_key?(formatted.metadata, :format)
        refute Map.has_key?(formatted.metadata, "format")
        assert formatted.metadata[:request_id] == "r1"
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "F: plain_text falls back when markdown parser errors" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text}}
        )

        outgoing = %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: <<255>>,
          metadata: %{request_id: "r1"}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == <<255>>
        assert formatted.metadata[:format] == :plain_text
        assert formatted.metadata[:request_id] == "r1"
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "G: html falls back when markdown parser errors" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :html}}
        )

        outgoing = %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: <<255>>,
          metadata: %{request_id: "r1"}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == <<255>>
        assert formatted.metadata[:format] == :html
        assert formatted.metadata[:request_id] == "r1"
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "H: Earmark error tuple keeps source markdown" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :html}}
        )

        markdown = "```elixir\nfoo"

        outgoing = %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: markdown,
          metadata: %{request_id: "r1"}
        }

        assert_raise CaseClauseError, fn -> MessageFormatter.format_outgoing(outgoing) end
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "J: budget exceeded link appended for non-web provider when portal_url is set" do
      original_portal = Application.get_env(:zaq, :user_portal_base_url)

      try do
        Application.put_env(:zaq, :user_portal_base_url, "https://portal.example.com")

        outgoing = %Outgoing{
          provider: :mattermost,
          channel_id: "c1",
          body: "You ran out.",
          metadata: %{error_type: :budget_exceeded}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "You ran out.\nTop up your wallet: https://portal.example.com"
      after
        Application.put_env(:zaq, :user_portal_base_url, original_portal)
      end
    end

    test "J-contrast: budget exceeded body unchanged when portal_url is nil" do
      original_portal = Application.get_env(:zaq, :user_portal_base_url)

      try do
        Application.put_env(:zaq, :user_portal_base_url, nil)

        outgoing = %Outgoing{
          provider: :mattermost,
          channel_id: "c1",
          body: "You ran out.",
          metadata: %{error_type: :budget_exceeded}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "You ran out."
      after
        Application.put_env(:zaq, :user_portal_base_url, original_portal)
      end
    end

    test "K: unknown format atom falls back to original body" do
      original = Application.get_env(:zaq, :channels)

      try do
        Application.put_env(
          :zaq,
          :channels,
          %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :json}}
        )

        outgoing = %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: "hello world",
          metadata: %{}
        }

        formatted = MessageFormatter.format_outgoing(outgoing)

        assert formatted.body == "hello world"
      after
        Application.put_env(:zaq, :channels, original)
      end
    end

    test "I: invalid Earmark output falls back to the original body" do
      with_mocked_earmark_as_html(fn ->
        original = Application.get_env(:zaq, :channels)

        try do
          Application.put_env(
            :zaq,
            :channels,
            %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :html}}
          )

          outgoing = %Outgoing{
            provider: :web,
            channel_id: "c1",
            body: "# Title",
            metadata: %{request_id: "r1"}
          }

          formatted = MessageFormatter.format_outgoing(outgoing)

          assert formatted.body == "# Title"
          assert formatted.metadata[:format] == :html
          assert formatted.metadata[:request_id] == "r1"

          Application.put_env(
            :zaq,
            :channels,
            %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text}}
          )

          formatted = MessageFormatter.format_outgoing(outgoing)

          assert formatted.body == "# Title"
          assert formatted.metadata[:format] == :plain_text
          assert formatted.metadata[:request_id] == "r1"
        after
          Application.put_env(:zaq, :channels, original)
        end
      end)
    end
  end

  defp with_mocked_earmark_as_html(fun) when is_function(fun, 0) do
    :code.purge(Earmark)
    :code.delete(Earmark)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string("""
    defmodule Earmark do
      def as_html(_text, _opts), do: :weird
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    try do
      fun.()
    after
      :code.purge(Earmark)
      :code.delete(Earmark)
      :code.load_file(Earmark)
      Code.compiler_options(ignore_module_conflict: false)
    end
  end
end
