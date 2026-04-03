defmodule ZaqWeb.Live.BO.System.ForgotPasswordLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Swoosh.TestAssertions

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  describe "GET /bo/forgot-password" do
    test "renders the forgot password form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/bo/forgot-password")

      assert html =~ "Password Reset"
      assert html =~ "Send Reset Link"
    end
  end

  describe "submitting the form with a known email" do
    test "sends reset email and shows success page", %{conn: conn} do
      insert_smtp_channel(enabled: true)

      user = user_fixture()
      {:ok, _user} = Accounts.update_user(user, %{email: "valid@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/bo/forgot-password")

      html =
        lv
        |> form("form", %{email: "valid@example.com"})
        |> render_submit()

      assert html =~ "Check your inbox"
      assert_email_sent(subject: "Reset your ZAQ password")
    end
  end

  describe "submitting the form with an unknown email" do
    test "shows an error and does not send email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/forgot-password")

      html =
        lv
        |> form("form", %{email: "ghost@example.com"})
        |> render_submit()

      assert html =~ "No account found with that email address"
      refute html =~ "Check your inbox"
      assert_no_email_sent()
    end

    test "clears error when email field is changed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/forgot-password")

      # Submit with unknown email to trigger error
      lv |> form("form", %{email: "ghost@example.com"}) |> render_submit()

      # Validate (change) clears the error
      html = lv |> element("form") |> render_change(%{email: "new@example.com"})
      refute html =~ "No account found"
    end
  end

  defp insert_smtp_channel(attrs) do
    settings = %{
      "relay" => "",
      "port" => "587",
      "transport_mode" => "starttls",
      "tls" => "enabled",
      "tls_verify" => "verify_peer",
      "from_email" => "noreply@example.com",
      "from_name" => "ZAQ"
    }

    attrs_map = Enum.into(attrs, %{})

    from(c in ChannelConfig, where: c.provider == "email:smtp")
    |> Repo.delete_all()

    params =
      %{
        name: "Email SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        url: "smtp://configured-in-settings",
        token: "smtp-unused",
        enabled: true,
        settings: settings
      }
      |> Map.merge(attrs_map)

    %ChannelConfig{}
    |> ChannelConfig.changeset(params)
    |> Repo.insert!()
  end
end
