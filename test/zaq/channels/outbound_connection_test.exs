defmodule Zaq.Channels.OutboundConnectionTest do
  use Zaq.DataCase, async: true

  import Zaq.TestSupport.ChannelFileFixtures, only: [connector!: 2]

  alias Zaq.Channels.{Bridge, DeliveryError, EmailBridge, JidoChatBridge}
  alias Zaq.Engine.Messages.Outgoing

  test "SMTP binding reuses the selected inbox while still validating the sender" do
    smtp = connector!("email:smtp", %{"send_on_file_failure" => false})

    imap =
      connector!("email:imap", %{
        "imap" => %{"smtp_config_id" => smtp.id, "selected_mailboxes" => ["INBOX"]}
      })

    outgoing = %Outgoing{
      body: "Answer",
      channel_id: "recipient@example.test",
      provider: :"email:imap",
      routing_context: %{channel_config_id: imap.id}
    }

    {result, queries} =
      Zaq.QueryRecorder.capture(fn ->
        EmailBridge.fetch_connection_details_for_config(imap, outgoing: outgoing)
      end)

    assert {:ok, %{smtp_config_id: sender_id, attachment_failure_policy: :abort}} = result
    assert sender_id == smtp.id
    connector_queries = Enum.filter(queries, &(&1.source == "channel_configs"))
    assert Enum.any?(connector_queries, &(smtp.id in &1.params))
    refute Enum.any?(connector_queries, &(imap.id in &1.params))
  end

  test "email ingress lookup remains independent of its outbound SMTP binding" do
    smtp = connector!("email:smtp", %{"send_on_file_failure" => false})

    imap =
      connector!("email:imap", %{
        "imap" => %{"smtp_config_id" => smtp.id, "selected_mailboxes" => ["INBOX"]},
        "send_on_file_failure" => true
      })

    outgoing = %Outgoing{
      body: "Answer",
      channel_id: "recipient@example.test",
      provider: :"email:imap",
      routing_context: %{channel_config_id: imap.id}
    }

    ingress_details = Bridge.fetch_connection_details_for_config(imap)
    assert EmailBridge.fetch_connection_details_for_config(imap) == ingress_details

    assert {:ok, %{smtp_config_id: smtp_id, attachment_failure_policy: :abort}} =
             EmailBridge.fetch_connection_details_for_config(imap, outgoing: outgoing)

    assert smtp_id == smtp.id

    smtp |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    assert EmailBridge.fetch_connection_details_for_config(imap) == ingress_details

    assert {:error, %DeliveryError{delivery: :not_sent}} =
             EmailBridge.fetch_connection_details_for_config(imap, outgoing: outgoing)
  end

  test "Jido inherits the existing lookup without a separate delivery callback" do
    config = connector!("mattermost", %{"send_on_file_failure" => false})
    expected = Bridge.fetch_connection_details_for_config(config)
    outgoing = %Outgoing{body: "Answer", channel_id: "room", provider: :mattermost}

    assert JidoChatBridge.fetch_connection_details_for_config(config) == expected

    assert {:ok, details} =
             JidoChatBridge.fetch_connection_details_for_config(config, outgoing: outgoing)

    assert details == Map.put(expected, :attachment_failure_policy, :abort)
    refute function_exported?(JidoChatBridge, :delivery_connection, 2)
    refute function_exported?(EmailBridge, :delivery_connection, 2)
  end
end
