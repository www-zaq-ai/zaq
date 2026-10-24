defmodule Zaq.Channels.WhatsAppMarkdownDeliveryTest do
  @moduledoc """
  Regression contract for Markdown replies delivered through the real WhatsApp
  adapter. Only the external transport is replaced; the shared formatter uses
  the application's provider configuration.
  """

  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing

  @jid "15551234567@s.whatsapp.net"
  @markdown "**Ready**: *review* the ~~old~~ value. Keep `**literal**` unchanged."
  @whatsapp "*Ready*: _review_ the ~old~ value. Keep `**literal**` unchanged."

  defmodule Transport do
    @moduledoc false

    def resolve_conn(_opts), do: {:ok, self()}

    def send_text(conn, jid, text, _opts) do
      send(conn, {:whatsapp_send, jid, text})
      {:ok, "reply-1"}
    end

    def send_edit(conn, key, text) do
      send(conn, {:whatsapp_edit, key, text})
      {:ok, "status-1"}
    end
  end

  test "new replies render Markdown as WhatsApp formatting without changing code" do
    outgoing = formatted_reply()

    assert {:ok, _response} =
             Adapter.send_message(outgoing.channel_id, outgoing.body,
               transport: Transport,
               format: outgoing.metadata[:format]
             )

    assert_received {:whatsapp_send, @jid, text}
    assert text == @whatsapp
  end

  test "status-message edits render Markdown as WhatsApp formatting without changing code" do
    outgoing = formatted_reply()

    assert {:ok, _response} =
             Adapter.edit_message(outgoing.channel_id, "status-1", outgoing.body,
               transport: Transport,
               format: outgoing.metadata[:format]
             )

    assert_received {:whatsapp_edit, {@jid, "status-1", true}, text}
    assert text == @whatsapp
  end

  defp formatted_reply do
    MessageFormatter.format_outgoing(%Outgoing{
      provider: :whatsapp,
      channel_id: @jid,
      body: @markdown,
      metadata: %{}
    })
  end
end
