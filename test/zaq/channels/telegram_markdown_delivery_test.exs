defmodule Zaq.Channels.TelegramMarkdownDeliveryTest do
  @moduledoc """
  End-to-end coverage of the agent-reply -> Telegram markdown delivery path.

  Walks the real seam, stubbing only the adapter (the external boundary):

      %Outgoing{provider: :telegram}
        -> Zaq.Channels.Api (:deliver_outgoing)
        -> Zaq.Channels.MessageFormatter (markdown -> body untouched, format stamped)
        -> Zaq.Channels.JidoChatBridge.do_send_reply/2
        -> adapter send_message/3 or edit_message/4 with `format: :markdown`

  ZAQ speaks one canonical format here: markdown, unconverted. How that reaches a
  user is the adapter's problem — `jido_chat_telegram` maps `:markdown` onto Bot API
  10.1 rich messages precisely because Telegram's `sendMessage` parse modes are a
  subset with no tables. None of that vocabulary belongs on this side of the seam.

  The regression these tests exist for: ZAQ posts a status placeholder and then
  *edits* it with the answer, so `edit_message/4` — not `send_message/3` — is the
  hop that actually carries a real reply. A format that survives only the send path
  silently ships raw markdown to users.
  """

  use Zaq.DataCase, async: false

  alias Jido.Chat.Telegram.Adapter, as: TelegramAdapter
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

  defmodule StubTelegramTransport do
    @moduledoc false
    @behaviour Jido.Chat.Telegram.Transport

    @impl true
    def call(_token, method, payload, _opts) do
      send(self(), {:transport_call, method, payload})
      {:ok, %{"message_id" => 42, "chat" => %{"id" => 99}, "date" => 1}}
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
        message_format: :markdown
      })
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    # Hand back the real compiled config so a test can assert on what
    # `config/config.exs` actually declares, not on this stub.
    {:ok, real_channels: previous}
  end

  describe "channel configuration" do
    test "telegram is configured to ship markdown" do
      # Guards the premise of every other test here. MessageFormatter is a no-op
      # unless the provider declares :message_format, so a config regression would
      # otherwise let the suite pass while users receive raw markdown.
      telegram = Application.get_env(:zaq, :channels, %{}) |> Map.get(:telegram, %{})

      assert telegram[:bridge] == JidoChatBridge
      assert telegram[:message_format] == :markdown
    end

    test "the real application config declares markdown for telegram", ctx do
      # Asserts on the config compiled from config/config.exs, captured before the
      # setup stub replaced it. Telegram can rely on the formatter's nil/unset
      # default: canonical markdown is stamped unless a provider explicitly opts out.
      telegram = Map.get(ctx.real_channels, :telegram, %{})

      assert telegram[:adapter] == TelegramAdapter
      assert telegram[:message_format] in [nil, :markdown]

      # A custom formatter would convert the body and defeat adapter-side rendering.
      refute Map.has_key?(telegram, :message_formatter)
    end

    test "no telegram-specific format leaks into the channel config", ctx do
      # The reviewer's boundary: `:rich_markdown` is jido_chat_telegram vocabulary.
      telegram = Map.get(ctx.real_channels, :telegram, %{})

      refute telegram[:message_format] in [:rich_markdown, :rich_html, :rich]
    end
  end

  describe "MessageFormatter with :markdown" do
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
      assert formatted.metadata[:format] == :markdown
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

    test "an adapter-specific format is not a ZAQ format and is never stamped" do
      # Configuring a Telegram-only format here would push adapter vocabulary through
      # the generic seam. It is unknown to the formatter, so it is dropped rather than
      # forwarded — the bridge has nothing to pass on.
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        put_in(previous, [:telegram, :message_format], :rich_markdown)
      )

      outgoing = %Outgoing{
        provider: :telegram,
        channel_id: "chat-1",
        body: "**bold**",
        metadata: %{}
      }

      formatted = MessageFormatter.format_outgoing(outgoing)

      assert formatted.body == "**bold**"
      refute Map.has_key?(formatted.metadata, :format)
    end
  end

  describe "delivery through the bridge" do
    test "a new reply reaches the adapter as markdown" do
      assert {:ok, _receipt} = deliver(@table_reply, %{request_id: "req-1"})

      assert_received {:adapter_send_message, "chat-1", text, opts}
      assert opts[:format] == :markdown
      assert text =~ "| Champion | Spain | Won 1-0 |"
      refute text =~ "<table"
    end

    test "an edited reply reaches the adapter as markdown" do
      # The path real traffic takes: a status placeholder already exists, so the
      # answer is delivered by editing it rather than by sending a new message.
      assert {:ok, _receipt} = deliver(@table_reply, %{request_id: "req-1", message_id: "msg-1"})

      assert_received {:adapter_edit_message, "chat-1", "msg-1", text, opts}
      assert opts[:format] == :markdown
      assert text =~ "| Champion | Spain | Won 1-0 |"
    end

    test "the body delivered is byte-identical to the agent's markdown" do
      assert {:ok, _receipt} = deliver(@table_reply, %{message_id: "msg-1"})

      assert_received {:adapter_edit_message, _chat, _msg, text, _opts}
      assert text == @table_reply
    end
  end

  describe "adapter contract" do
    # ZAQ hands the adapter `:markdown` and stops caring. This is the far end of that
    # contract: the real adapter has to be the thing that turns it into a renderer
    # capable of tables. Stubbing only the HTTP transport keeps that mapping under test
    # — if the dep is ever repointed at a build where `:markdown` means MarkdownV2,
    # tables regress and this fails.
    test "the real telegram adapter renders :markdown through a rich message" do
      assert {:ok, _response} =
               TelegramAdapter.send_message(99, @table_reply,
                 token: "bot-token",
                 transport: StubTelegramTransport,
                 format: :markdown
               )

      assert_received {:transport_call, "sendRichMessage", payload}
      assert payload["rich_message"] == %{"markdown" => @table_reply}
      refute Map.has_key?(payload, "parse_mode")
    end

    test "the real telegram adapter renders an edited :markdown reply the same way" do
      assert {:ok, _response} =
               TelegramAdapter.edit_message(99, 7, @table_reply,
                 token: "bot-token",
                 transport: StubTelegramTransport,
                 format: :markdown
               )

      assert_received {:transport_call, "editMessageText", payload}
      assert payload["rich_message"] == %{"markdown" => @table_reply}
      refute Map.has_key?(payload, "text")
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
