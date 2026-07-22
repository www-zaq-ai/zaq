defmodule Zaq.Channels.TelegramRichMessageDeliveryTest do
  @moduledoc """
  End-to-end coverage of the agent-reply -> Telegram rich message delivery path.

  Walks the real seam, stubbing only the adapter (the external boundary):

      %Outgoing{provider: :telegram}
        -> Zaq.Channels.Api (:deliver_outgoing)
        -> Zaq.Channels.MessageFormatter (rich_markdown -> body untouched, format stamped)
        -> Zaq.Channels.JidoChatBridge.do_send_reply/2
        -> adapter send_message/3 or edit_message/4 with `format: :rich_markdown`

  Telegram's `sendMessage` HTML parse mode has a closed tag set with no `<table>`,
  so markdown tables can only render through Bot API 10.1 rich messages, which take
  the body verbatim and parse it server-side. Every hop here therefore has to leave
  the markdown *unconverted* and carry `:rich_markdown` through to the adapter — the
  opposite of what the `:html` providers do.

  The regression these tests exist for: ZAQ posts a status placeholder and then
  *edits* it with the answer, so `edit_message/4` — not `send_message/3` — is the
  hop that actually carries a real reply. A format that survives only the send path
  silently ships raw markdown to users.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  @table_reply """
  **2010 FIFA World Cup**

  | Stage | Teams | Result |
  |-------|-------|--------|
  | Champion | Spain | Won 1-0 |

  ### Quick recap
  - **Winner:** Spain
  """

  defmodule StubTelegramAdapter do
    @moduledoc false

    def send_message(channel_id, text, opts) do
      send(self(), {:adapter_send_message, channel_id, text, opts})
      {:ok, %{external_message_id: "post-123"}}
    end

    def edit_message(channel_id, message_id, text, opts) do
      send(self(), {:adapter_edit_message, channel_id, message_id, text, opts})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:zaq, :channels, %{})

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :telegram, %{
        bridge: JidoChatBridge,
        adapter: StubTelegramAdapter,
        ingress_mode: :webhook,
        message_format: :rich_markdown
      })
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    # Hand back the real compiled config so a test can assert on what
    # `config/config.exs` actually declares, not on this stub.
    {:ok, real_channels: previous}
  end

  describe "channel configuration" do
    test "telegram is configured to ship rich markdown" do
      # Guards the premise of every other test here. MessageFormatter is a no-op
      # unless the provider declares :message_format, so a config regression would
      # otherwise let the suite pass while users receive raw markdown.
      telegram = Application.get_env(:zaq, :channels, %{}) |> Map.get(:telegram, %{})

      assert telegram[:bridge] == JidoChatBridge
      assert telegram[:message_format] == :rich_markdown
    end

    test "the real application config still declares rich markdown for telegram", ctx do
      # Asserts on the config compiled from config/config.exs, captured before the
      # setup stub replaced it, so deleting `message_format: :rich_markdown` there
      # fails the suite instead of silently shipping raw markdown.
      telegram = Map.get(ctx.real_channels, :telegram, %{})

      assert telegram[:adapter] == Jido.Chat.Telegram.Adapter
      assert telegram[:message_format] == :rich_markdown

      # A custom formatter would convert the body and defeat rich parsing.
      refute Map.has_key?(telegram, :message_formatter)
    end
  end

  describe "MessageFormatter with :rich_markdown" do
    test "leaves the markdown table untouched and stamps the format" do
      outgoing = %Outgoing{
        provider: :telegram,
        channel_id: "chat-1",
        body: @table_reply,
        metadata: %{request_id: "req-1"}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == @table_reply
      assert formatted.body =~ "| Champion | Spain | Won 1-0 |"
      assert formatted.body =~ "**2010 FIFA World Cup**"
      assert formatted.metadata[:format] == :rich_markdown
      assert formatted.metadata[:request_id] == "req-1"
    end

    test "does not convert markdown to html the way :html providers do" do
      outgoing = %Outgoing{
        provider: :telegram,
        channel_id: "chat-1",
        body: "# Title\n\n**bold**",
        metadata: %{}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      refute formatted.body =~ "<h1>"
      refute formatted.body =~ "<strong>"
      assert formatted.body == "# Title\n\n**bold**"
    end

    test "supports :rich_html for providers that opt into html rich bodies" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        put_in(previous, [:telegram, :message_format], :rich_html)
      )

      outgoing = %Outgoing{
        provider: :telegram,
        channel_id: "chat-1",
        body: "<b>bold</b>",
        metadata: %{}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "<b>bold</b>"
      assert formatted.metadata[:format] == :rich_html
    end
  end

  describe "delivery through the bridge" do
    test "a new reply reaches the adapter as rich markdown" do
      assert {:ok, _receipt} = deliver(@table_reply, %{request_id: "req-1"})

      assert_received {:adapter_send_message, "chat-1", text, opts}
      assert opts[:format] == :rich_markdown
      assert text =~ "| Champion | Spain | Won 1-0 |"
      refute text =~ "<table"
    end

    test "an edited reply reaches the adapter as rich markdown" do
      # The path real traffic takes: a status placeholder already exists, so the
      # answer is delivered by editing it rather than by sending a new message.
      assert {:ok, _receipt} = deliver(@table_reply, %{request_id: "req-1", message_id: "msg-1"})

      assert_received {:adapter_edit_message, "chat-1", "msg-1", text, opts}
      assert opts[:format] == :rich_markdown
      assert text =~ "| Champion | Spain | Won 1-0 |"
    end

    test "the body delivered is byte-identical to the agent's markdown" do
      assert {:ok, _receipt} = deliver(@table_reply, %{message_id: "msg-1"})

      assert_received {:adapter_edit_message, _chat, _msg, text, _opts}
      assert text == @table_reply
    end
  end

  defp deliver(body, metadata) do
    upsert_telegram_channel()

    %Outgoing{
      body: body,
      channel_id: "chat-1",
      provider: :telegram,
      metadata: metadata
    }
    |> Event.new(:channels, opts: [action: :deliver_outgoing])
    |> Api.handle_event(:deliver_outgoing, nil)
    |> Map.fetch!(:response)
  end

  defp upsert_telegram_channel do
    assert {:ok, _channel} =
             ChannelConfig.upsert_by_provider("telegram", %{
               name: "Telegram",
               kind: "retrieval",
               enabled: true,
               url: "https://api.telegram.org",
               token: "bot-token"
             })

    :ok
  end
end
