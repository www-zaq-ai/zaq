defmodule ZaqWeb.Live.BO.Communication.NotificationImapLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  defmodule RouterStubOk do
    def list_mailboxes("email:imap", _config), do: {:ok, ["INBOX", "Support", "Sales"]}
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubSlow do
    def list_mailboxes("email:imap", _config) do
      Process.sleep(120)
      {:ok, ["INBOX", "Support"]}
    end

    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubError do
    def list_mailboxes("email:imap", _config), do: {:error, :auth_failed}
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubConnectError do
    def list_mailboxes("email:imap", _config), do: {:error, {:connect_failed, :econnrefused}}
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubListError do
    def list_mailboxes("email:imap", _config), do: {:error, {:list_mailboxes_failed, :timeout}}
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubRaise do
    def list_mailboxes("email:imap", _config), do: raise("boom")
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubExit do
    def list_mailboxes("email:imap", _config), do: exit(:killed)
    def sync_provider_runtime("email:imap"), do: :ok
  end

  defmodule RouterStubSyncError do
    def list_mailboxes("email:imap", _config), do: {:ok, ["INBOX"]}
    def sync_provider_runtime("email:imap"), do: {:error, :sync_failed}
  end

  defmodule RouterStubSyncNil do
    def list_mailboxes("email:imap", _config), do: {:ok, ["INBOX"]}
    def sync_provider_runtime("email:imap"), do: nil
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

  test "renders mailbox and provider agent routing controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    assert has_element?(view, "#imap-provider-default-agent-select")
    assert has_element?(view, "#imap-mailbox-agent-assignments")
  end

  test "mailbox assignment controls track selected mailboxes only", %{conn: conn} do
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

    assert_eventually(fn ->
      has_element?(view, "#imap-selected-mailboxes option[value='Support']")
    end)

    assert has_element?(view, "select[name='imap_config[mailbox_agent_ids][INBOX]']")
    refute has_element?(view, "select[name='imap_config[mailbox_agent_ids][Support]']")

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "secret",
        "selected_mailboxes" => ["INBOX", "Support"]
      }
    })

    assert has_element?(view, "select[name='imap_config[mailbox_agent_ids][Support]']")

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

    refute has_element?(view, "select[name='imap_config[mailbox_agent_ids][Support]']")
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
    assert channel.settings["imap"]["username"] == "zaq@example.com"
    assert channel.settings["imap"]["ssl_depth"] == 3
    assert channel.settings["imap"]["selected_mailboxes"] == ["INBOX", "Support"]
    assert has_element?(view, "#save-status-ok")

    {:ok, reloaded_view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    assert has_element?(
             reloaded_view,
             "#imap-config-form input[name='imap_config[username]'][value='zaq@example.com']"
           )
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

    assert_eventually(fn ->
      has_element?(view, "#imap-mailboxes-status-ok", "Mailboxes loaded")
    end)

    assert_eventually(fn ->
      has_element?(view, "#imap-selected-mailboxes option[value='Support']")
    end)
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

    assert_eventually(fn -> has_element?(view, "#imap-mailboxes-status-error") end)
    assert_eventually(fn -> render(view) =~ "Connection failed while loading IMAP mailboxes" end)
  end

  test "mailbox load error is preserved across validate events", %{conn: conn} do
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

    assert_eventually(fn -> has_element?(view, "#imap-mailboxes-status-error") end)
    assert_eventually(fn -> render(view) =~ "Connection failed while loading IMAP mailboxes" end)

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "secret",
        "port" => "994",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    assert_eventually(fn -> has_element?(view, "#imap-mailboxes-status-error") end)
    assert_eventually(fn -> render(view) =~ "Connection failed while loading IMAP mailboxes" end)
  end

  test "load mailboxes shows validation error when connection fields are missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-error")
    assert render(view) =~ "IMAP URL is required before loading mailboxes"
  end

  test "load mailboxes validates missing username and password", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "",
        "password" => "",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-error")
    assert render(view) =~ "IMAP username is required before loading mailboxes"

    view
    |> element("#imap-config-form")
    |> render_change(%{
      "imap_config" => %{
        "url" => "imap.example.com",
        "username" => "zaq@example.com",
        "password" => "",
        "selected_mailboxes" => ["INBOX"]
      }
    })

    view |> element("#load-imap-mailboxes") |> render_click()

    assert has_element?(view, "#imap-mailboxes-status-error")
    assert render(view) =~ "IMAP password is required before loading mailboxes"
  end

  test "load mailboxes maps connect_failed errors", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubConnectError)

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

    assert_eventually(fn -> render(view) =~ "Unable to connect to IMAP server" end)
    assert_eventually(fn -> render(view) =~ "Connection refused. Check URL and port." end)
  end

  test "load mailboxes maps list_mailboxes_failed errors", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubListError)

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

    assert_eventually(fn -> render(view) =~ "Unable to load mailboxes from IMAP server" end)
    assert_eventually(fn -> render(view) =~ "Connection timed out." end)
  end

  test "load mailboxes handles raised exceptions in adapter call", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubRaise)

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

    assert_eventually(fn -> render(view) =~ "Connection failed while loading IMAP mailboxes" end)
    assert_eventually(fn -> render(view) =~ "boom" end)
  end

  test "load mailboxes handles exit signals in adapter call", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubExit)

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

    assert_eventually(fn -> render(view) =~ "Connection failed while loading IMAP mailboxes" end)
    assert_eventually(fn -> render(view) =~ "killed" end)
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

    assert_eventually(fn ->
      has_element?(view, "#imap-mailboxes-status-ok", "Mailboxes loaded")
    end)

    assert_eventually(fn ->
      has_element?(view, "#imap-selected-mailboxes option[value='Support']")
    end)
  end

  test "save shows changeset errors for invalid enabled config", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view
    |> element("#imap-config-form")
    |> render_submit(%{
      "imap_config" => %{
        "enabled" => "true",
        "url" => "",
        "port" => "993",
        "ssl_depth" => "3",
        "ssl" => "true",
        "username" => "",
        "password" => "",
        "selected_mailboxes" => [],
        "mark_as_read" => "true",
        "poll_interval" => "30000",
        "idle_timeout" => "1500000"
      }
    })

    assert has_element?(view, "#save-status-error")
  end

  test "save shows runtime sync flash when sync fails", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubSyncError)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

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
        "selected_mailboxes" => ["INBOX"],
        "mark_as_read" => "true",
        "poll_interval" => "30000",
        "idle_timeout" => "1500000"
      }
    })

    assert_eventually(fn -> render(view) =~ "IMAP runtime sync failed" end)
  end

  test "activate toggles enabled state", %{conn: conn} do
    insert_smtp_enabled()

    channel =
      insert_imap_channel(%{
        enabled: false,
        settings: %{
          "imap" => %{"username" => "zaq@example.com", "selected_mailboxes" => ["INBOX"]}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("button[phx-click='activate']") |> render_click()
    assert Repo.get!(ChannelConfig, channel.id).enabled

    view |> element("button[phx-click='activate']") |> render_click()
    refute Repo.get!(ChannelConfig, channel.id).enabled
  end

  test "activate shows changeset error when enabling invalid config", %{conn: conn} do
    insert_imap_channel(%{
      enabled: false,
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("button[phx-click='activate']") |> render_click()

    assert has_element?(view, "#save-status-error")
    assert render(view) =~ "is required when IMAP is enabled"
  end

  test "activate shows runtime sync flash when sync fails", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubSyncError)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

    insert_smtp_enabled()

    insert_imap_channel(%{
      enabled: false,
      url: "imap.example.com",
      settings: %{
        "imap" => %{
          "username" => "zaq@example.com",
          "selected_mailboxes" => ["INBOX"]
        }
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("button[phx-click='activate']") |> render_click()

    assert_eventually(fn -> render(view) =~ "IMAP runtime sync failed" end)
  end

  test "activate keeps success path when sync returns nil", %{conn: conn} do
    Application.put_env(:zaq, :notification_imap_router_module, RouterStubSyncNil)

    on_exit(fn ->
      Application.delete_env(:zaq, :notification_imap_router_module)
    end)

    insert_smtp_enabled()

    insert_imap_channel(%{
      enabled: false,
      url: "imap.example.com",
      settings: %{
        "imap" => %{
          "username" => "zaq@example.com",
          "selected_mailboxes" => ["INBOX"]
        }
      }
    })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")

    view |> element("button[phx-click='activate']") |> render_click()

    assert has_element?(view, "button[phx-click='activate']", "Deactivate")
  end

  test "ignores unrelated info messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/imap")
    send(view.pid, :unknown_message)
    assert render(view) =~ "IMAP Settings"
  end

  defp insert_imap_channel(attrs) do
    defaults = %{
      name: "Email IMAP",
      kind: "retrieval",
      url: "imap.example.com",
      token: "imap-secret",
      enabled: false,
      settings: %{
        "imap" => %{
          "username" => "zaq@example.com",
          "selected_mailboxes" => ["INBOX"]
        }
      }
    }

    {:ok, channel} =
      ChannelConfig.upsert_by_provider("email:imap", Map.merge(defaults, attrs))

    channel
  end

  defp insert_smtp_enabled do
    {:ok, _smtp} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "Email SMTP",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "smtp.example.com", "port" => "587"}
      })
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end
end
