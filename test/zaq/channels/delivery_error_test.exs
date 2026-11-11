defmodule Zaq.Channels.DeliveryErrorTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Channels.{Api, DeliveryError, DeliveryFiles, EmailBridge}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule SmtpAdapter do
    use Swoosh.Adapter

    def deliver(email, _config) do
      send(self(), :smtp_attempt)
      send(self(), {:smtp_email, email})

      case Process.get(:smtp_failure) do
        nil -> {:ok, "accepted"}
        reason -> {:error, reason}
      end
    end
  end

  property "preparation errors preserve their reason without disclosing arbitrary content" do
    check all(reason <- string(:printable)) do
      error = DeliveryFiles.delivery_error(reason)
      assert error.reason == reason
      assert error.message == "The attachment content could not be accessed."
      assert error.stage == :preparation
      assert error.delivery == :not_sent
      refute inspect(error) =~ "reason:"
    end
  end

  describe "email delivery" do
    setup do
      previous = Application.get_env(:zaq, Zaq.Mailer)
      Application.put_env(:zaq, Zaq.Mailer, adapter: SmtpAdapter)
      on_exit(fn -> Application.put_env(:zaq, Zaq.Mailer, previous) end)

      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Delivery error SMTP",
          provider: "email:smtp",
          url: "smtp.example.test",
          token: "fixture-token",
          kind: "retrieval",
          enabled: true,
          settings: %{"from_email" => "sender@example.test"}
        })
        |> Repo.insert!()

      %{smtp_config: config}
    end

    test "email preparation failure reports detail without attempting SMTP", %{
      smtp_config: config
    } do
      record = %Record{
        id: "file",
        kind: :file,
        content: "%%%",
        attributes: %{"encoding" => "base64"}
      }

      assert {:error, %DeliveryError{} = error} =
               EmailBridge.send_reply(%{outgoing(config.id) | attachments: [record]}, %{})

      assert error.reason == :invalid_attachment_base64
      assert error.message == "The attachment contains invalid Base64 content."
      assert error.stage == :preparation
      assert error.delivery == :not_sent
      refute_received :smtp_attempt
    end

    test "SMTP errors retain transport facts and safe specific messages", %{smtp_config: config} do
      for {reason, message, delivery} <- [
            {{:no_more_hosts, {:permanent_failure, "private-host", :auth_failed}},
             "SMTP authentication failed.", :not_sent},
            {{:no_more_hosts, {:permanent_failure, "private-host", :ssl_not_started}},
             "The secure SMTP connection could not be initialized.", :not_sent},
            {{:retries_exceeded, {:missing_requirement, "private-host", :auth}},
             "The SMTP server does not support the required authentication.", :not_sent},
            {{:retries_exceeded, {:missing_requirement, "private-host", :tls}},
             "The SMTP server does not support the required secure connection.", :not_sent},
            {{:retries_exceeded, {:temporary_failure, "private-host", :tls_failed}},
             "A secure SMTP connection could not be established.", :not_sent},
            {{:retries_exceeded, {:network_failure, "private-host", {:error, :econnrefused}}},
             "The SMTP server could not be reached.", :not_sent},
            {{:send, {:network_failure, "private-host", {:error, :timeout}}},
             "SMTP delivery timed out; delivery could not be confirmed.", :unconfirmed},
            {{:send, {:permanent_failure, "private-host", "550 private recipient"}},
             "The SMTP server rejected the email.", :not_sent},
            {{:unexpected, "private diagnostic"}, "Email delivery could not be confirmed.",
             :unconfirmed}
          ] do
        Process.put(:smtp_failure, reason)

        assert {:error, %DeliveryError{} = error} =
                 EmailBridge.send_reply(outgoing(config.id), %{})

        assert error.reason == reason
        assert error.message == message
        assert error.stage == :transport
        assert error.delivery == delivery
        refute inspect(error) =~ "private"
        assert_received :smtp_attempt
        refute_received :smtp_attempt

        record = %Record{id: "file", kind: :file, content: "file bytes"}

        outgoing = %{
          outgoing(config.id)
          | attachments: [record],
            metadata: %{message_id: "email-id"}
        }

        event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
        assert {:error, ^error} = Api.handle_event(event, :deliver_outgoing, nil).response
        assert_received :smtp_attempt
        refute_received :smtp_attempt
      end
    end

    test "email preparation failure sends the original message once and retains safe failure evidence",
         %{
           smtp_config: config
         } do
      record = %Record{
        id: "file",
        kind: :file,
        content: "%%%",
        attributes: %{"encoding" => "base64"}
      }

      outgoing = %{
        outgoing(config.id)
        | attachments: [record],
          metadata: %{html_body: "<p>Keep this answer</p>"}
      }

      event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

      assert {:ok,
              %{
                confirmation: :partial,
                messages: [%{confirmation: :confirmed}],
                failed_files: [failure]
              }} =
               Api.handle_event(event, :deliver_outgoing, nil).response

      assert failure.stage == :preparation
      assert failure.reason == "The attachment contains invalid Base64 content."
      refute inspect(failure) =~ "%%%"

      assert_received :smtp_attempt
      assert_received {:smtp_email, email}
      assert email.attachments == []

      assert email.text_body == "Keep this answer"
      assert email.html_body == "<p>Keep this answer</p>"
      refute_received :smtp_attempt
    end
  end

  defp outgoing(config_id) do
    %Outgoing{
      provider: :"email:smtp",
      channel_id: "recipient@example.test",
      body: "Keep this answer",
      routing_context: %{channel_config_id: config_id}
    }
  end
end
