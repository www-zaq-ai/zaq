defmodule Zaq.Engine.Messages.Incoming.AudienceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  test "ignores malformed participant entries and preserves later valid evidence" do
    sender = "sender@example.com"
    recipient = "recipient@example.com"

    audience =
      Audience.normalize(%{
        platform: "email",
        sender: sender,
        recipients: [recipient],
        participants: [
          %{identifier: sender, role: :sender},
          nil,
          "unexpected",
          %{identifier: recipient},
          %{identifier: recipient, role: :bcc},
          %{identifier: recipient, role: "to"},
          %{identifier: recipient, role: :cc, display_name: "Recipient"}
        ]
      })

    assert %Audience{platform: "email", sender: ^sender, recipients: [^recipient]} = audience

    assert audience.participants == [
             %{identifier: sender, role: :sender, display_name: nil},
             %{identifier: recipient, role: :cc, display_name: "Recipient"}
           ]
  end

  test "non-list participant metadata defaults to an empty participant list" do
    audience =
      Audience.normalize(%{
        platform: "email",
        sender: "sender@example.com",
        recipients: ["recipient@example.com"],
        participants: %{
          identifier: "recipient@example.com",
          role: :to,
          display_name: "Recipient"
        }
      })

    assert %Audience{
             platform: "email",
             sender: "sender@example.com",
             recipients: ["recipient@example.com"],
             participants: []
           } = audience
  end

  property "normalizes only valid participants in input order" do
    sender = "sender@example.com"
    recipient = "recipient@example.com"

    valid =
      member_of([
        %{identifier: sender, role: :sender},
        %{identifier: recipient, role: :to, display_name: "Recipient"},
        %{identifier: recipient, role: :cc, display_name: nil}
      ])

    invalid =
      member_of([
        nil,
        "unexpected",
        %{identifier: recipient},
        %{identifier: recipient, role: :bcc},
        %{identifier: recipient, role: "to"},
        %{identifier: "outsider@example.com", role: :to}
      ])

    check all(entries <- list_of(one_of([valid, invalid]), max_length: 20), max_runs: 50) do
      expected =
        Enum.flat_map(entries, fn
          %{identifier: id, role: role} = participant
          when role in [:sender, :to, :cc] and id in [sender, recipient] ->
            [%{identifier: id, role: role, display_name: Map.get(participant, :display_name)}]

          _ ->
            []
        end)

      audience =
        Audience.normalize(%{
          platform: "email",
          sender: sender,
          recipients: [recipient],
          participants: entries
        })

      assert %Audience{platform: "email", sender: ^sender, recipients: [^recipient]} = audience
      assert audience.participants == expected
    end
  end
end
