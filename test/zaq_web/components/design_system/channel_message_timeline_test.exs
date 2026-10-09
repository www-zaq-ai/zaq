defmodule ZaqWeb.Components.DesignSystem.ChannelMessageTimelineTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.ChannelMessageTimeline

  test "renders an accessible empty transcript" do
    html = render_component(&ChannelMessageTimeline.channel_message_timeline/1, messages: [])

    assert html =~ ~s(<ol class="zaq-layout-stack" aria-label="Transcript messages">)
    refute html =~ "<li"
    refute html =~ "Attachment:"
  end

  test "renders ordered messages and attachment descriptors" do
    messages = [
      message(%{
        author_name: "Mina",
        author_id: "mina-7",
        role: "user",
        position: 1,
        content: "Agenda attached",
        attachments: [%{"name" => "agenda.pdf", "id" => "a1"}, %{"id" => "b2"}]
      }),
      message(%{
        author_name: nil,
        author_id: "agent-9",
        role: "assistant",
        position: 2,
        content: "I will review it",
        attachments: []
      })
    ]

    html =
      render_component(&ChannelMessageTimeline.channel_message_timeline/1, messages: messages)

    rows = Regex.scan(~r/<li\b[^>]*>.*?<\/li>/s, html) |> Enum.map(&hd/1)

    assert length(rows) == 2
    [first, second] = rows
    assert first =~ "Mina"
    refute first =~ "mina-7"
    assert first =~ "user"
    assert first =~ "Position 1"
    assert first =~ "Agenda attached"
    assert second =~ "agent-9"
    assert second =~ "assistant"
    assert second =~ "Position 2"
    assert second =~ "I will review it"
    assert length(Regex.scan(~r/<p\b[^>]*class="zaq-field-helper"[^>]*>/, first)) == 2
    assert first =~ "Attachment: agenda.pdf (descriptor only)"
    assert first =~ "Attachment: b2 (descriptor only)"
    refute second =~ "Attachment:"
  end

  test "renders fallback author and descriptor-only file label without controls" do
    html =
      render_component(&ChannelMessageTimeline.channel_message_timeline/1,
        messages: [message(%{author_name: nil, author_id: nil, attachments: [%{}]})]
      )

    assert html =~ "Unknown author"
    assert html =~ "Attachment: File (descriptor only)"
    refute html =~ "<a"
    refute html =~ "<button"
  end

  test "escapes untrusted interpolated strings as text" do
    unsafe = "<script>unsafe</script>"

    html =
      render_component(&ChannelMessageTimeline.channel_message_timeline/1,
        messages: [
          message(%{
            author_name: unsafe,
            role: unsafe,
            content: unsafe,
            attachments: [%{"name" => unsafe}]
          })
        ]
      )

    assert html =~ "&lt;script&gt;unsafe&lt;/script&gt;"
    refute html =~ unsafe
    refute html =~ "<a"
  end

  defp message(overrides) do
    Map.merge(
      %{
        author_name: "Alex",
        author_id: "alex-1",
        role: "user",
        position: 1,
        content: "Hello",
        attachments: []
      },
      overrides
    )
  end
end
