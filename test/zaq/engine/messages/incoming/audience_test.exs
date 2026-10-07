defmodule Zaq.Engine.Messages.Incoming.AudienceTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.Incoming.Audience

  test "accepts more than 100 recipients and preserves all participant metadata" do
    recipients = Enum.map(1..150, &"recipient#{&1}@example.com")
    sender = "sender@example.com"

    participants =
      [%{identifier: sender, role: :sender, display_name: "Sender"}] ++
        Enum.map(recipients, fn identifier ->
          %{identifier: identifier, role: :to, display_name: identifier}
        end)

    assert %Audience{} =
             audience =
             Audience.normalize(%{
               platform: "email",
               sender: sender,
               recipients: recipients,
               participants: participants
             })

    assert audience.recipients == recipients
    assert audience.participants == participants
  end

  test "filters invalid metadata without truncating later valid participants" do
    participant = %{identifier: "recipient@example.com", role: :cc, display_name: "Recipient"}

    audience =
      Audience.normalize(%{
        platform: "email",
        sender: "sender@example.com",
        recipients: [participant.identifier],
        participants:
          List.duplicate(%{identifier: "outsider@example.com", role: :to}, 101) ++ [participant]
      })

    assert audience.participants == [participant]
  end
end
