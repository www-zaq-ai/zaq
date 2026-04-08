defmodule ZaqWeb.Live.BO.Communication.NotificationImapLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig

  defmodule RouterStubOk do
    def list_mailboxes("email:imap", _config), do: {:ok, ["INBOX", "Support", "Sales"]}
    def sync_config_runtime(_before, _after), do: :ok
  end

  defmodule RouterStubSlow do
    def list_mailboxes("email:imap", _config) do
      Process.sleep(120)
      {:ok, ["INBOX", "Support"]}
    end

    def sync_config_runtime(_before, _after), do: :ok
  end

  defmodule RouterStubError do
    def list_mailboxes("email:imap", _config), do: {:error, :auth_failed}
    def sync_config_runtime(_before, _after), do: :ok
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    %{conn: conn, user: user}
  end

  test "mounts IMAP form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    assert has_element?(view, "#imap-config-form")
    assert has_element?(view, "#imap-selected-mailboxes")
    assert has_element?(view, "button[phx-click='activate']")
  end

  test "save persists IMAP provider configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_submit(%{
      "imap_config" => %{
        "enabled" => "false",
        "url" => "imap.example.com",
        "port" => "993",
        "ssl_depth" => "3",
        "ssl" => "true",
        "username" => "zaq@example.com",
        "password" => "secret",
        "selected_mailboxes" => ["INBOX", "Support"],
        "mark_as_read" => "true",
        "poll_interval" => "30000",
        "idle_timeout" => "1500000"
      }
    })

    channel = ChannelConfig.get_any_by_provider("email:imap")
    assert channel
    assert channel.url == "imap.example.com"
    assert channel.settings["imap"]["ssl_depth"] == 3
    assert channel.settings["imap"]["selected_mailboxes"] == ["INBOX", "Support"]
    assert has_element?(view, "#save-status-ok")
  end

  test "load mailboxes updates multiselect options", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubOk)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "secret",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-ok", "Mailboxes loaded")
    assert has_element?(view, "#imap-selected-mailboxes option[value='Support']")
  end

  test "load mailboxes shows clean connection error", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubError)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "secret",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-error")
    assert render(view) =~ "Connection failed while loading IMAP mailboxes"
  end

  test "load mailboxes shows validation error when connection fields are missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-error")
    assert render(view) =~ "IMAP URL is required before loading mailboxes"
  end

  test "load mailboxes with slow adapter still resolves and updates options", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubSlow)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "secret",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    _ = view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-ok", "Mailboxes loaded")
    assert has_element?(view, "#imap-selected-mailboxes option[value='Support']")
  end
end
