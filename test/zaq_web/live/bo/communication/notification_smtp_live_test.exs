defmodule ZaqWeb.Live.BO.Communication.NotificationSmtpLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.System.SecretConfig

  setup :verify_on_exit!

  setup %{conn: conn} do
    previous_mailer_config = Application.get_env(:zaq, Zaq.Mailer)
    Application.put_env(:zaq, Zaq.Mailer, adapter: Swoosh.Adapters.Local)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Mailer, previous_mailer_config)
    end)

    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    %{conn: conn, user: user}
  end

  test "mounts with defaults when no smtp config exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    assert has_element?(view, "#smtp-config-form")
    assert has_element?(view, "#test-email-form")
    assert has_element?(view, "button[phx-click='activate']", "Activate")
  end

  test "loads existing smtp config values", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "smtp.mail.internal",
        "port" => "2525",
        "transport_mode" => "starttls",
        "tls" => "always",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => "/etc/ssl/custom.pem",
        "username" => "mailer",
        "password" => "plaintext-password",
        "from_email" => "ops@example.com",
        "from_name" => "Ops Bot"
      }
    })

    {:ok, _view, html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    assert html =~ "smtp.mail.internal"
    assert html =~ "2525"
    assert html =~ "ops@example.com"
    assert html =~ "Ops Bot"
    assert html =~ "Deactivate"
  end

  test "validate renders smtp security warnings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-config-form")
    |> render_change(%{
      "email_config" => %{
        "enabled" => "false",
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "ssl",
        "tls" => "never",
        "tls_verify" => "verify_none",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    assert has_element?(view, "#smtp-warning-ssl-port")
    assert has_element?(view, "#smtp-warning-tls-never")
    assert has_element?(view, "#smtp-warning-verify-none")
  end

  test "save persists config and encrypts password", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-config-form")
    |> render_submit(%{
      "email_config" => %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => "",
        "username" => "mailer@example.com",
        "password" => "super-secret",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    channel = ChannelConfig.get_any_by_provider("email:smtp")
    assert channel
    assert channel.settings["relay"] == "smtp.example.com"
    assert channel.settings["from_email"] == "noreply@example.com"
    assert is_binary(channel.settings["password"])
    assert SecretConfig.encrypted?(channel.settings["password"])

    assert has_element?(view, "#save-status-ok")
  end

  test "save shows changeset errors for invalid data", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-config-form")
    |> render_submit(%{
      "email_config" => %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => "",
        "username" => "",
        "password" => "",
        "from_email" => "not-an-email",
        "from_name" => "ZAQ"
      }
    })

    assert has_element?(view, "#save-status-error")
  end

  test "save handles missing encryption key", %{conn: conn} do
    with_secret_config([encryption_key: nil, key_id: "test-v1"], fn ->
      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      view
      |> element("#smtp-config-form")
      |> render_submit(%{
        "email_config" => %{
          "relay" => "smtp.example.com",
          "port" => "587",
          "transport_mode" => "starttls",
          "tls" => "enabled",
          "tls_verify" => "verify_peer",
          "ca_cert_path" => "",
          "username" => "mailer@example.com",
          "password" => "super-secret",
          "from_email" => "noreply@example.com",
          "from_name" => "ZAQ"
        }
      })

      assert render(view) =~ "Missing encryption key for sensitive settings."
    end)
  end

  test "save handles invalid encryption key", %{conn: conn} do
    with_secret_config([encryption_key: "bad-key", key_id: "test-v1"], fn ->
      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      view
      |> element("#smtp-config-form")
      |> render_submit(%{
        "email_config" => %{
          "relay" => "smtp.example.com",
          "port" => "587",
          "transport_mode" => "starttls",
          "tls" => "enabled",
          "tls_verify" => "verify_peer",
          "ca_cert_path" => "",
          "username" => "mailer@example.com",
          "password" => "super-secret",
          "from_email" => "noreply@example.com",
          "from_name" => "ZAQ"
        }
      })

      assert render(view) =~ "Invalid encryption key configuration."
    end)
  end

  test "activate toggles enabled state in both directions", %{conn: conn} do
    channel =
      insert_smtp_channel(%{
        enabled: false,
        settings: %{
          "relay" => "smtp.example.com",
          "port" => "587",
          "transport_mode" => "starttls",
          "tls" => "enabled",
          "tls_verify" => "verify_peer",
          "from_email" => "noreply@example.com",
          "from_name" => "ZAQ"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view |> element("button[phx-click='activate']") |> render_click()
    assert Repo.get!(ChannelConfig, channel.id).enabled

    view |> element("button[phx-click='activate']") |> render_click()
    refute Repo.get!(ChannelConfig, channel.id).enabled
  end

  test "activate shows changeset error when enabling invalid config", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: false,
      settings: %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view |> element("button[phx-click='activate']") |> render_click()

    assert has_element?(view, "#save-status-error")
  end

  test "test_connection validates recipient presence and format", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view |> element("#test-email-form") |> render_submit(%{"recipient" => ""})
    assert render(view) =~ "Enter a recipient email to send a test."

    view |> element("#test-email-form") |> render_submit(%{"recipient" => "invalid"})
    assert render(view) =~ "Recipient must be a valid email address."
  end

  test "test_connection enters loading then reports not configured", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#test-email-form")
    |> render_submit(%{"recipient" => "user@example.com"})

    assert render(view) =~ "Email is not configured or disabled."
  end

  test "validate with safe defaults shows no smtp warnings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-config-form")
    |> render_change(%{
      "email_config" => %{
        "enabled" => "false",
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    refute has_element?(view, "#smtp-security-warnings")
  end

  test "validate can show selective warning only", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-config-form")
    |> render_change(%{
      "email_config" => %{
        "enabled" => "false",
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "ssl",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    assert has_element?(view, "#smtp-warning-ssl-port")
    refute has_element?(view, "#smtp-warning-tls-never")
    refute has_element?(view, "#smtp-warning-verify-none")
  end

  test "test_connection without recipient param returns required error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#test-email-form")
    |> render_submit(%{})

    assert render(view) =~ "Enter a recipient email to send a test."
  end

  test "test_connection direct event with missing params hits fallback handler", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    render_submit(view, "test_connection", %{})

    assert {:error, "Enter a recipient email to send a test."} = current_test_status(view)
  end

  test "test_connection keeps raw recipient value while validating trimmed version", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#test-email-form")
    |> render_submit(%{"recipient" => "  invalid  "})

    html = render(view)
    assert html =~ "Recipient must be a valid email address."
    assert html =~ "value=\"  invalid  \""
  end

  test "test_connection surfaces binary mailer error directly", %{conn: conn} do
    insert_enabled_smtp_channel()
    put_failing_mailer("plain smtp failure")

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert {:error, "plain smtp failure"} = current_test_status(view)
    assert render(view) =~ "plain smtp failure"
  end

  test "test_connection formats retry exhaustion reasons", %{conn: conn} do
    for {reason, expected, detail} <- [
          {{:retries_exceeded, {:missing_requirement, "smtp.example.com", :auth}},
           "SMTP authentication is unavailable.",
           "Details: {:missing_requirement, \"smtp.example.com\", :auth}"},
          {{:retries_exceeded, {:missing_requirement, "smtp.example.com", :tls}},
           "SMTP server requires TLS but TLS could not be established.",
           "Details: {:missing_requirement, \"smtp.example.com\", :tls}"},
          {{:retries_exceeded, nil}, "Could not reach the SMTP server.", nil},
          {{:retries_exceeded, "timeout"}, "Could not reach the SMTP server.",
           "Details: timeout"},
          {{:retries_exceeded, :closed}, "Could not reach the SMTP server.", "Details: closed"}
        ] do
      insert_enabled_smtp_channel()
      put_failing_mailer(reason)

      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      send(view.pid, {:send_test, "user@example.com"})
      _ = :sys.get_state(view.pid)

      assert {:error, message} = current_test_status(view)
      assert message =~ expected

      if detail do
        assert message =~ detail
      else
        refute message =~ "Details:"
      end
    end
  end

  test "test_connection formats known smtp delivery errors", %{conn: conn} do
    for {reason, expected} <- [
          {{:network_failure, :econnrefused}, "Network error while contacting the SMTP server."},
          {{:temporary_failure, :tls_failed},
           "TLS handshake failed. Check TLS verification mode or CA certificate path."},
          {{:error, :missing_encryption_key},
           "Missing SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."},
          {{:error, :invalid_encryption_key},
           "Invalid SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."},
          {{:error, :invalid_ciphertext},
           "Stored SMTP password cannot be decrypted. Please re-save the password with a valid encryption key."},
          {:invalid_ciphertext,
           "Stored SMTP password cannot be decrypted. Please re-save the password with a valid encryption key."},
          {:missing_encryption_key,
           "Missing SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."},
          {:invalid_encryption_key,
           "Invalid SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."},
          {{:unexpected, :boom}, "{:unexpected, :boom}"}
        ] do
      insert_enabled_smtp_channel()
      put_failing_mailer(reason)

      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      send(view.pid, {:send_test, "user@example.com"})
      _ = :sys.get_state(view.pid)

      assert {:error, ^expected} = current_test_status(view)
    end
  end

  test "test_connection uses enabled tls fallback mode", %{conn: conn} do
    insert_enabled_smtp_channel(%{
      "tls" => "enabled",
      "tls_verify" => "verify_none",
      "username" => "",
      "password" => nil
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  test "test_connection reports missing encryption key while decrypting password", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "enc:test-v1:AAAA:AAAA:AAAA",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    with_secret_config([encryption_key: nil, key_id: "test-v1"], fn ->
      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      send(view.pid, {:send_test, "user@example.com"})
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "missing_encryption_key"
    end)
  end

  test "test_connection reports invalid encryption key while decrypting password", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "enc:test-v1:AAAA:AAAA:AAAA",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    with_secret_config([encryption_key: "bad-key", key_id: "test-v1"], fn ->
      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

      send(view.pid, {:send_test, "user@example.com"})
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "invalid_encryption_key"
    end)
  end

  test "test_connection reports invalid ciphertext while decrypting password", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "enc:test-v1:not-b64:not-b64:not-b64",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert render(view) =~ "invalid_ciphertext"
  end

  test "test_connection surfaces unknown key id details", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "enc:test-v1:AAAA:AAAA:AAAA",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    with_secret_config(
      [
        encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
        key_id: "test-v2"
      ],
      fn ->
        {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

        send(view.pid, {:send_test, "user@example.com"})
        _ = :sys.get_state(view.pid)

        assert render(view) =~ "unknown_key_id"
      end
    )
  end

  test "test_connection attempts delivery with username omitted (auth never)", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "127.0.0.1",
        "port" => "2525",
        "transport_mode" => "starttls",
        "tls" => "never",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => "",
        "username" => "",
        "password" => nil,
        "from_email" => "sender@example.com",
        "from_name" => "Sender"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  test "test_connection attempts delivery with verify_none tls options", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "localhost",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "if_available",
        "tls_verify" => "verify_none",
        "ca_cert_path" => nil,
        "username" => "mailer@example.com",
        "password" => nil,
        "from_email" => "sender@example.com",
        "from_name" => "Sender"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  test "test_connection attempts delivery with required tls and custom ca path", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "localhost",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "always",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => "/tmp/custom-ca.pem",
        "username" => "mailer@example.com",
        "password" => "",
        "from_email" => "sender@example.com",
        "from_name" => "Sender"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  test "test_connection attempts delivery with ssl transport", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "localhost",
        "port" => "465",
        "transport_mode" => "ssl",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => "mailer@example.com",
        "password" => "",
        "from_email" => "sender@example.com",
        "from_name" => "Sender"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  test "test_connection attempts delivery with unknown tls mode fallback", %{conn: conn} do
    insert_smtp_channel(%{
      enabled: true,
      settings: %{
        "relay" => "localhost",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "weird_mode",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => "mailer@example.com",
        "password" => "",
        "from_email" => "sender@example.com",
        "from_name" => "Sender"
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert :ok = current_test_status(view)
  end

  defp with_secret_config(config, fun) do
    previous = Application.get_env(:zaq, Zaq.System.SecretConfig)

    Application.put_env(:zaq, Zaq.System.SecretConfig, config)

    try do
      fun.()
    after
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous)
    end
  end

  defp current_test_status(view) do
    state = :sys.get_state(view.pid)

    assigns =
      case state do
        %{socket: %{assigns: assigns}} -> assigns
        %{socket: socket} -> socket.assigns
        %{assigns: assigns} -> assigns
      end

    Map.fetch!(assigns, :test_status)
  end

  defp put_failing_mailer(reason) do
    previous_error = Application.get_env(:zaq, :smtp_live_test_error)

    Application.put_env(:zaq, Zaq.Mailer, adapter: ZaqWeb.NotificationSmtpLiveTest.ErrorAdapter)

    Application.put_env(:zaq, :smtp_live_test_error, reason)

    on_exit(fn ->
      if previous_error == nil do
        Application.delete_env(:zaq, :smtp_live_test_error)
      else
        Application.put_env(:zaq, :smtp_live_test_error, previous_error)
      end
    end)
  end

  defp insert_enabled_smtp_channel(attrs \\ %{}) do
    insert_smtp_channel(%{
      enabled: true,
      settings:
        Map.merge(
          %{
            "relay" => "smtp.example.com",
            "port" => "587",
            "transport_mode" => "starttls",
            "tls" => "enabled",
            "tls_verify" => "verify_peer",
            "ca_cert_path" => nil,
            "username" => "mailer@example.com",
            "password" => "",
            "from_email" => "sender@example.com",
            "from_name" => "Sender"
          },
          attrs
        )
    })
  end

  defp insert_smtp_channel(attrs) do
    defaults = %{
      name: "Email SMTP",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://configured-in-settings",
      token: "smtp-unused",
      enabled: false,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    }

    {:ok, channel} =
      ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    channel
  end
end

defmodule ZaqWeb.NotificationSmtpLiveTest.ErrorAdapter do
  @behaviour Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, Application.fetch_env!(:zaq, :smtp_live_test_error)}

  @impl true
  def deliver_many(emails, config), do: Enum.map(emails, &deliver(&1, config))

  @impl true
  def validate_config(_config), do: :ok
end
