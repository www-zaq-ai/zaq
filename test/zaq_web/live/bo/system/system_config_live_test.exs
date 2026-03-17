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
      {:ok, _view, html} = live(conn, ~p"/bo/system-config")
      assert html =~ "Email (SMTP)"
      assert html =~ "Enable email delivery"
      assert html =~ "email_config[relay]"
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
            "from_email" => "noreply@zaq.local",
            "from_name" => "ZAQ"
          }
        })
        |> render_change()

      assert html =~ "smtp.test.com"
    end
  end

  describe "save event" do
    test "with valid params persists config to the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("form[phx-submit='save']", %{
        "email_config" => %{
          "enabled" => "false",
          "relay" => "smtp.save.com",
          "port" => "587",
          "tls" => "enabled",
          "from_email" => "noreply@example.com",
          "from_name" => "ZAQ"
        }
      })
      |> render_submit()

      # Verify that the relay was saved to DB
      assert Zaq.System.get_config("email.relay") == "smtp.save.com"
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

  describe "set_test_recipient event" do
    test "updates the test_recipient assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      # The set_test_recipient event is triggered by phx-change on the recipient input
      html =
        view
        |> element("input[name='recipient']")
        |> render_change(%{"recipient" => "tester@example.com"})

      # After update, the input value should reflect the new recipient
      assert html =~ "tester@example.com"
    end
  end

  describe "test_connection event" do
    test "does not send when recipient is empty and keeps test_status idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      # test_recipient starts as "" — the view should put_flash and not change test_status
      view
      |> element("button[phx-click='test_connection']")
      |> render_click()

      # test_status stays :idle (no "Sending…" text, no error text in template)
      html = render(view)
      refute html =~ "Sending"
      refute html =~ "Email is not configured or disabled."
    end

    test "shows error status when email is not configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      # Set a recipient via phx-change
      view
      |> element("input[name='recipient']")
      |> render_change(%{"recipient" => "tester@example.com"})

      # Trigger test_connection — email not configured in test env
      view
      |> element("button[phx-click='test_connection']")
      |> render_click()

      # handle_info {:send_test, recipient} fires, finds :not_configured, sets test_status
      assert render(view) =~ "Email is not configured or disabled."
    end
  end
end
