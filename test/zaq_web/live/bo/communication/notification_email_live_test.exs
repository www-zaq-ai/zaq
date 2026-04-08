defmodule ZaqWeb.Live.BO.Communication.NotificationEmailLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    %{conn: conn, user: user}
  end

  test "renders IMAP and SMTP connection cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email")

    assert has_element?(view, "#connection-type-card-imap")
    assert has_element?(view, "#connection-type-card-imap", "IMAP")
    assert has_element?(view, "#connection-type-card-smtp")
    assert has_element?(view, "#connection-type-card-smtp", "SMTP")
  end

  test "shows not configured badge when SMTP channel is absent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email")

    assert has_element?(view, "#connection-type-card-smtp", "Not configured")
  end

  test "shows active badge when SMTP channel exists and enabled", %{conn: conn} do
    insert_smtp_channel(%{enabled: true})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email")

    assert has_element?(view, "#connection-type-card-smtp", "active")
  end

  test "shows service unavailable page when channels service is down", %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> nil end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email")

    assert has_element?(view, "h2", "Service Unavailable")
  end

  defp insert_smtp_channel(attrs) do
    defaults = %{
      name: "Email SMTP",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://configured-in-settings",
      token: "smtp-unused",
      enabled: true,
      settings: %{
        "relay" => "smtp.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    }

    {:ok, channel} =
      ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    channel
  end
end
