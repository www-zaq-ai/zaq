defmodule ZaqWeb.Live.BO.System.SystemConfigLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{email: "admin@example.com", username: "testadmin_sc"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  describe "mount" do
    test "renders the email configuration form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/bo/system-config")
      assert html =~ "Email (SMTP)"
      assert html =~ "Enable email delivery"
      assert html =~ "email_config[relay]"
      assert has_element?(view, "#smtp-advanced-section")
      assert has_element?(view, "#smtp-transport-mode")
      assert has_element?(view, "#smtp-tls-verify")
      assert has_element?(view, "#smtp-ca-cert-path")
      assert html =~ "system-config-tab-telemetry"
    end
  end

  describe "tab navigation" do
    test "switches to telemetry settings tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> element("#system-config-tab-telemetry")
        |> render_click()

      assert html =~ "Telemetry Collection"
      assert html =~ "telemetry_config[capture_infra_metrics]"
      assert html =~ "telemetry-config-form"
      refute html =~ "Test Email Delivery"
    end
  end

  describe "validate event" do
    test "updates the form without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> form("form[phx-submit='save']", %{
          "email_config" => %{
            "enabled" => "false",
            "relay" => "smtp.test.com",
            "port" => "25",
            "tls" => "enabled",
            "transport_mode" => "starttls",
            "tls_verify" => "verify_peer",
            "ca_cert_path" => "",
            "from_email" => "noreply@zaq.local",
            "from_name" => "ZAQ"
          }
        })
        |> render_change()

      assert html =~ "smtp.test.com"
    end
  end

  describe "telemetry save/validate" do
    test "validate telemetry form without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("#system-config-tab-telemetry")
      |> render_click()

      html =
        view
        |> form("#telemetry-config-form", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "250",
            "repo_query_duration_threshold_ms" => "15"
          }
        })
        |> render_change()

      assert html =~ "250"
      assert html =~ "15"

      assert Zaq.System.get_config("telemetry.request_duration_threshold_ms") == nil
      assert Zaq.System.get_config("telemetry.repo_query_duration_threshold_ms") == nil
    end

    test "save telemetry settings persists config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("#system-config-tab-telemetry")
      |> render_click()

      view
      |> form("#telemetry-config-form", %{
        "telemetry_config" => %{
          "capture_infra_metrics" => "false",
          "request_duration_threshold_ms" => "300",
          "repo_query_duration_threshold_ms" => "25"
        }
      })
      |> render_submit()

      assert Zaq.System.get_config("telemetry.capture_infra_metrics") == "false"
      assert Zaq.System.get_config("telemetry.request_duration_threshold_ms") == "300"
      assert Zaq.System.get_config("telemetry.repo_query_duration_threshold_ms") == "25"
    end
  end

  describe "save event" do
    test "with valid params persists config to the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> form("form[phx-submit='save']", %{
          "email_config" => %{
            "enabled" => "false",
            "relay" => "smtp.save.com",
            "port" => "587",
            "tls" => "enabled",
            "transport_mode" => "starttls",
            "tls_verify" => "verify_peer",
            "ca_cert_path" => "",
            "from_email" => "noreply@example.com",
            "from_name" => "ZAQ"
          }
        })
        |> render_submit()

      assert html =~ "Email configuration saved."
      assert has_element?(view, "#save-status-ok")
      # Verify that key email fields were saved to DB
      assert Zaq.System.get_config("email.relay") == "smtp.save.com"
      assert Zaq.System.get_config("email.from_email") == "noreply@example.com"
    end

    test "with enabled=true but no relay shows validation errors in form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> form("form[phx-submit='save']", %{
          "email_config" => %{
            "enabled" => "true",
            "relay" => "",
            "port" => "587",
            "tls" => "enabled",
            "transport_mode" => "starttls",
            "tls_verify" => "verify_peer",
            "ca_cert_path" => "",
            "from_email" => "noreply@example.com",
            "from_name" => "ZAQ"
          }
        })
        |> render_submit()

      # Form re-renders with error; relay field should remain in the form
      assert html =~ "email_config[relay]"
      # Nothing saved to DB
      assert Zaq.System.get_config("email.relay") == nil
    end
  end

  describe "test email form" do
    test "keeps recipient value after submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> form("#test-email-form", %{"recipient" => "tester@example.com"})
        |> render_submit()

      assert html =~ "tester@example.com"
    end
  end

  describe "advanced SMTP warnings" do
    test "shows ssl port warning when ssl mode uses non-465 port", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#system-config-form", %{
        "email_config" => %{"transport_mode" => "ssl", "port" => "587"}
      })
      |> render_change()

      assert has_element?(view, "#smtp-security-warnings")
      assert has_element?(view, "#smtp-warning-ssl-port")
    end

    test "shows verify_none warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#system-config-form", %{"email_config" => %{"tls_verify" => "verify_none"}})
      |> render_change()

      assert has_element?(view, "#smtp-warning-verify-none")
    end
  end

  describe "test_connection event" do
    test "does not send when recipient is empty and shows inline validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#test-email-form", %{"recipient" => ""})
      |> render_submit()

      html = render(view)
      refute html =~ "Sending"
      assert html =~ "Enter a recipient email to send a test."
    end

    test "shows validation error when recipient is not a valid email", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#test-email-form", %{"recipient" => "not-an-email"})
      |> render_submit()

      assert render(view) =~ "Recipient must be a valid email address."
    end

    test "shows error status when email is not configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#test-email-form", %{"recipient" => "tester@example.com"})
      |> render_submit()

      assert render(view) =~ "Email is not configured or disabled."
    end
  end
end
