defmodule Zaq.Channels.EmailHtmlDeliveryTest do
  @moduledoc """
  End-to-end coverage of the agent-reply -> email HTML delivery path.

  Walks the real seam, with no stubbed hops in between:

      %Outgoing{provider: :email}
        -> Zaq.Channels.Api (:deliver_outgoing)
        -> Zaq.Channels.Bridge resolves Zaq.Channels.EmailBridge
        -> Zaq.Channels.MessageFormatter (markdown -> HTML, driven by real config)
        -> Zaq.Channels.EmailBridge.send_reply/2
        -> Zaq.Engine.Notifications.EmailNotification
        -> Swoosh (captured via Swoosh.Adapters.Test)

  The bridge is resolved from the real `config :zaq, :channels` entry rather than
  a test stub: if `email: %{message_format: :html}` is dropped from config, these
  tests fail instead of silently shipping raw markdown to recipients.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  @markdown """
  # Deployment status

  The **build** passed. See [the run](https://ci.example.com) for details.

  - migrations applied
  - cache warmed
  """

  describe "agent reply delivered as HTML email" do
    test "email provider is configured to format outbound bodies as html" do
      # Guards the premise of every other test in this file. MessageFormatter is
      # a no-op unless the provider declares :message_format, so a config
      # regression here would otherwise make the suite pass on unformatted mail.
      email_config = Application.get_env(:zaq, :channels, %{}) |> Map.get(:email, %{})

      assert email_config[:bridge] == Zaq.Channels.EmailBridge
      assert email_config[:message_format] == :html
    end

    test "markdown agent reply reaches SMTP as converted html" do
      upsert_smtp_channel()

      assert :ok = deliver(@markdown, %{"subject" => "Deploy report"})

      assert_receive {:email, email}

      assert email.subject == "Deploy report"
      assert email.to == [{"", "ops@example.com"}]

      # --- the conversion actually happened ---
      assert email.html_body =~ "<h1>"
      assert email.html_body =~ "Deployment status"
      assert email.html_body =~ "<strong>build</strong>"
      assert email.html_body =~ ~s(href="https://ci.example.com")
      assert email.html_body =~ "<li>"
      assert email.html_body =~ "migrations applied"

      # --- and no markdown syntax survived into the recipient's inbox ---
      refute email.html_body =~ "**build**"
      refute email.html_body =~ "# Deployment status"
      refute email.html_body =~ "[the run]"
      refute email.html_body =~ "- migrations applied"
    end

    test "text part is the de-tagged twin of the html part" do
      upsert_smtp_channel()

      assert :ok = deliver(@markdown, %{"subject" => "Deploy report"})

      assert_receive {:email, email}

      # Multipart alternative: readable text for clients that refuse HTML.
      assert is_binary(email.text_body)
      assert email.text_body =~ "Deployment status"
      assert email.text_body =~ "build passed"
      assert email.text_body =~ "migrations applied"

      refute email.text_body =~ "<h1>"
      refute email.text_body =~ "<strong>"
      refute email.text_body =~ "<li>"
      refute email.text_body =~ "**"
    end

    test "html special characters in the agent reply are escaped, not injected" do
      upsert_smtp_channel()

      body = "Compare `a < b` and <script>alert('xss')</script> in **prod**."

      assert :ok = deliver(body, %{"subject" => "Escaping"})

      assert_receive {:email, email}

      assert email.html_body =~ "<strong>prod</strong>"
      # The raw tag must arrive escaped, never as a live element.
      refute email.html_body =~ "<script>"
      assert email.html_body =~ "&lt;script&gt;"
    end

    test "formatter stamps the html format so EmailNotification picks the html branch" do
      upsert_smtp_channel()

      # Regression guard for the Api -> EmailBridge handoff: EmailBridge reads
      # `format` out of metadata to decide which body becomes the HTML part.
      # If MessageFormatter stops stamping it, text and html silently swap roles.
      assert :ok = deliver("**bold**", %{"subject" => "Format relay"})

      assert_receive {:email, email}

      assert email.html_body =~ "<strong>bold</strong>"
      refute email.text_body =~ "<strong>"
      assert email.text_body =~ "bold"
    end

    # An agent reply to an IMAP-received mail carries the provider verbatim from
    # the incoming message (`Outgoing.from_incoming/2`), and the IMAP parser
    # stamps `:"email:imap"` — not `:email`. The formatter must map that back to
    # the `:email` config key, or replies ship as raw markdown.
    test "markdown is converted for replies on the :\"email:imap\" provider" do
      upsert_smtp_channel()

      assert :ok = deliver(@markdown, %{"subject" => "IMAP reply"}, :"email:imap")

      assert_receive {:email, email}

      assert email.html_body =~ "<h1>"
      assert email.html_body =~ "<strong>build</strong>"
      assert email.html_body =~ "<li>"

      refute email.html_body =~ "**build**"
      refute email.html_body =~ "# Deployment status"
    end

    test "markdown is converted for the string form of the imap provider" do
      upsert_smtp_channel()

      assert :ok = deliver(@markdown, %{"subject" => "IMAP reply"}, "email:imap")

      assert_receive {:email, email}

      assert email.html_body =~ "<strong>build</strong>"
      refute email.html_body =~ "**build**"
    end

    test "routing metadata survives formatting" do
      upsert_smtp_channel()

      assert :ok =
               deliver("**hi**", %{
                 "subject" => "Metadata",
                 "request_id" => "req-42"
               })

      assert_receive {:email, email}

      assert email.subject == "Metadata"
      assert email.html_body =~ "<strong>hi</strong>"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Drives the real Channels API boundary — no bridge_module override, so
  # Zaq.Channels.Bridge resolves the email bridge from application config.
  defp deliver(body, metadata, provider \\ :email) do
    outgoing = %Outgoing{
      body: body,
      channel_id: "ops@example.com",
      provider: provider,
      metadata: metadata
    }

    outgoing
    |> Event.new(:channels, opts: [action: :deliver_outgoing])
    |> Api.handle_event(:deliver_outgoing, nil)
    |> Map.fetch!(:response)
  end

  defp smtp_settings(overrides \\ %{}) do
    Map.merge(
      %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => nil,
        "password" => nil,
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      },
      overrides
    )
  end

  defp upsert_smtp_channel(attrs \\ %{}) do
    defaults = %{
      name: "Email SMTP",
      kind: "retrieval",
      enabled: true,
      settings: smtp_settings()
    }

    assert {:ok, _channel} =
             ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    :ok
  end
end
