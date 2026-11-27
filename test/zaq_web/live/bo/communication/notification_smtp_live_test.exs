defmodule ZaqWeb.Live.BO.Communication.NotificationSmtpLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.ChannelCapabilityFixtures
  import Zaq.AccountsFixtures

  alias ZaqWeb.Live.BO.Communication.CapabilitySnapshot

  test "missing capability responses fail while errors without new facts retain the cache" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, capabilities_snapshot: %{}, capabilities_error: false}
    }

    assert CapabilitySnapshot.recover(socket, %{}) == socket
    failed = CapabilitySnapshot.apply_result(socket, nil)
    assert failed.assigns.capabilities_error
  end

  test "successful empty capability snapshots are cached on every settings page" do
    observe_capability_lookups()

    for module <- [
          ZaqWeb.Live.BO.Communication.NotificationSmtpLive,
          ZaqWeb.Live.BO.Communication.NotificationImapLive,
          ZaqWeb.Live.BO.Communication.WebWidgetLive
        ] do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          capabilities_snapshot: %{},
          capabilities_error: false,
          capability_modal_open: false
        }
      }

      assert {:noreply, opened} = module.handle_event("open_capabilities", %{}, socket)
      assert opened.assigns.capability_modal_open
      refute opened.assigns.capabilities_error
      assert opened.assigns.capabilities_snapshot == %{}
    end

    assert capability_lookup_count() == 0
  end

  test "capability failures retry on open and recovered snapshots stay cached", %{conn: conn} do
    channels = remove_capability_bridge(:email)
    observe_capability_lookups()
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    assert capability_lookup_count() == 2

    view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
    assert has_element?(view, "#capabilities-modal", "Capabilities unavailable")
    assert capability_lookup_count() == 3
    view |> element("[data-testid='channel-capabilities-close']") |> render_click()
    refute has_element?(view, "#capabilities-modal")

    Application.put_env(:zaq, :channels, channels)
    view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
    assert has_element?(view, "#capabilities-modal li", "Mode: none")
    refute has_element?(view, "#capabilities-modal", "Capabilities unavailable")
    assert capability_lookup_count() == 4

    view |> element("[data-testid='channel-capabilities-close']") |> render_click()
    view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
    assert has_element?(view, "#capabilities-modal li", "Mode: none")
    assert capability_lookup_count() == 4
  end

  alias Zaq.Accounts
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event
  alias Zaq.Repo
  alias Zaq.System.SecretConfig

  defmodule DeclaredSmtpBridge do
    alias Zaq.Channels.EmailBridge

    def capability_snapshot(config) do
      {:ok, snapshot} = EmailBridge.capability_snapshot(config)

      {:ok,
       put_in(snapshot, [:file_delivery, :limits, :max_attachment_bytes, :validation], %{
         greater_than: 1_000_000,
         less_than_or_equal_to: 2_000_000
       })}
    end
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    previous_sender = Application.get_env(:zaq, :email_bridge_smtp_module)
    previous_owner = Application.get_env(:zaq, :smtp_live_test_owner)
    previous_result = Application.get_env(:zaq, :smtp_live_test_result)
    previous_error = Application.get_env(:zaq, :smtp_live_test_error)
    Application.put_env(:zaq, :email_bridge_smtp_module, ZaqWeb.NotificationSmtpLiveTest.Sender)
    Application.put_env(:zaq, :smtp_live_test_owner, self())

    on_exit(fn ->
      restore_env(:email_bridge_smtp_module, previous_sender)
      restore_env(:smtp_live_test_owner, previous_owner)
      restore_env(:smtp_live_test_result, previous_result)
      restore_env(:smtp_live_test_error, previous_error)
    end)

    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    %{conn: conn, user: user}
  end

  test "SMTP tabs retain credentials, false policy and inactive advanced controls on save", %{
    conn: conn
  } do
    config = insert_smtp_channel(%{})
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")

    assert has_element?(
             view,
             "#smtp-settings-selector button[phx-value-tab='main'][aria-pressed=true]"
           )

    assert has_element?(view, "#smtp-settings-panel-advanced[hidden] #smtp-transport-mode")

    view
    |> form("#smtp-config-form", %{"email_config" => tabbed_smtp_params()})
    |> render_change()

    for tab <- ~w(advanced main advanced main) do
      view |> element("#smtp-settings-selector button[phx-value-tab='#{tab}']") |> render_click()
      assert has_element?(view, "#smtp-settings-panel-#{tab}:not([hidden])")
      assert has_element?(view, "#smtp-password[value='draft-password']")
      assert has_element?(view, "#smtp-ca-cert-path[value='/tmp/draft-ca.pem']")

      refute has_element?(
               view,
               "input[name='email_config[file_delivery][send_on_file_failure]'][type=checkbox][checked]"
             )

      assert Repo.reload!(config).settings == config.settings
    end

    view |> form("#smtp-config-form") |> render_submit()
    assert has_element?(view, "#save-status-ok")
    saved = Repo.reload!(config)
    assert saved.settings["relay"] == "draft.example.com"
    assert saved.settings["ca_cert_path"] == "/tmp/draft-ca.pem"
    assert SecretConfig.decrypt(saved.settings["password"]) == {:ok, "draft-password"}

    assert saved.settings["file_delivery"] == %{
             "max_attachment_bytes" => 1_000_001,
             "send_on_file_failure" => false
           }

    {:ok, reloaded, _} = live(conn, "/bo/channels/retrieval/email/smtp")

    assert has_element?(
             reloaded,
             "#smtp-settings-selector button[phx-value-tab='main'][aria-pressed=true]"
           )

    assert has_element?(reloaded, "#smtp-file-delivery-max_attachment_mb[value='1.000001']")
  end

  for {label, main?, advanced?} <- [
        {"Main", true, false},
        {"Advanced", false, true},
        {"both tabs", true, true}
      ] do
    @tag main_error: main?, advanced_error: advanced?
    test "SMTP rejected save selects #{label} errors and preserves all submitted drafts",
         context do
      config = insert_smtp_channel(%{})
      {:ok, view, _} = live(context.conn, "/bo/channels/retrieval/email/smtp")
      inactive = if context.main_error, do: "advanced", else: "main"

      view
      |> element("#smtp-settings-selector button[phx-value-tab='#{inactive}']")
      |> render_click()

      params = tabbed_smtp_params()
      params = if context.main_error, do: Map.put(params, "from_email", "invalid"), else: params

      params =
        if context.advanced_error,
          do: put_in(params, ["file_delivery", "max_attachment_mb"], "0.0000001"),
          else: params

      render_submit(view, "save", %{"email_config" => params})

      selected = if context.main_error, do: "main", else: "advanced"

      assert has_element?(
               view,
               "#smtp-settings-selector button[phx-value-tab='#{selected}'][aria-pressed=true]",
               "Errors"
             )

      if context.main_error && context.advanced_error,
        do:
          assert(
            has_element?(
              view,
              "#smtp-settings-selector button[phx-value-tab='advanced']",
              "Errors"
            )
          )

      assert has_element?(view, "#smtp-password[value='draft-password']")
      assert has_element?(view, "#smtp-ca-cert-path[value='/tmp/draft-ca.pem']")
      assert has_element?(view, "input[name='email_config[relay]'][value='draft.example.com']")

      refute has_element?(
               view,
               "input[name='email_config[file_delivery][send_on_file_failure]'][type=checkbox][checked]"
             )

      saved = Repo.reload!(config)
      assert saved.settings == config.settings
      assert saved.name == config.name
    end
  end

  test "blank configuration name preserves SMTP drafts and selects Main after persistence rejection",
       %{conn: conn} do
    config = insert_smtp_channel(%{})
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    view |> element("#smtp-settings-selector button[phx-value-tab='advanced']") |> render_click()
    params = Map.put(tabbed_smtp_params(), "connector_name", "")
    render_submit(view, "save", %{"email_config" => params})
    assert has_element?(view, "#smtp-settings-panel-main:not([hidden])")
    assert has_element?(view, "#smtp-connector-name[value='']")
    assert has_element?(view, "input[name='email_config[relay]'][value='draft.example.com']")
    assert has_element?(view, "#smtp-password[value='draft-password']")
    assert has_element?(view, "#smtp-file-delivery-max_attachment_mb[value='1.000001']")
    assert render(view) =~ "can&#39;t be blank"
    assert Repo.reload!(config).settings == config.settings
    assert Repo.reload!(config).name == config.name

    render_submit(view, "save", %{
      "email_config" => Map.put(params, "connector_name", "Recovered SMTP")
    })

    assert has_element?(view, "#save-status-ok")
    assert Repo.reload!(config).name == "Recovered SMTP"
    assert Repo.reload!(config).settings["relay"] == "draft.example.com"
    assert Repo.reload!(config).settings["file_delivery"]["send_on_file_failure"] == false
  end

  defp tabbed_smtp_params do
    %{
      "relay" => "draft.example.com",
      "port" => "587",
      "from_email" => "draft@example.com",
      "password" => "draft-password",
      "transport_mode" => "starttls",
      "tls_verify" => "verify_peer",
      "ca_cert_path" => "/tmp/draft-ca.pem",
      "file_delivery" => %{"max_attachment_mb" => "1.000001", "send_on_file_failure" => "false"}
    }
  end

  test "SMTP rejected saves refresh controls and retain connection and credential drafts", %{
    conn: conn
  } do
    config = insert_smtp_channel(%{})
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.update!(channels, :email, &Map.put(&1, :bridge, DeclaredSmtpBridge))
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
    params = put_in(tabbed_smtp_params(), ["file_delivery", "max_attachment_mb"], "3")
    render_submit(view, "save", %{"email_config" => params})
    assert has_element?(view, "#smtp-file-delivery-max_attachment_mb[max='2'][value='3']")
    assert has_element?(view, "input[name='email_config[relay]'][value='draft.example.com']")
    assert has_element?(view, "input[name='email_config[password]'][value='draft-password']")
    refute has_element?(view, "#smtp-file-delivery-send_on_file_failure[checked]")
    assert Repo.reload!(config).settings == config.settings

    render_submit(view, "save", %{
      "email_config" => put_in(params, ["file_delivery", "max_attachment_mb"], "1.5")
    })

    assert has_element?(view, "#save-status-ok")
    assert Repo.reload!(config).settings["file_delivery"]["max_attachment_bytes"] == 1_500_000
  end

  test "SMTP capability recovery retains drafts and validate does not perform lookups", %{
    conn: conn
  } do
    config = insert_smtp_channel(%{})
    channels = remove_capability_bridge(:email)
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    assert has_element?(view, "#smtp-file-delivery-unavailable", "Capabilities unavailable")
    observe_capability_lookups()
    render_change(view, "validate", %{"email_config" => tabbed_smtp_params()})
    assert capability_lookup_count() == 0
    Application.put_env(:zaq, :channels, channels)
    view |> element("#smtp-file-delivery button", "Retry capabilities") |> render_click()
    refute has_element?(view, "#smtp-file-delivery-unavailable")
    assert has_element?(view, "#smtp-password[value='draft-password']")
    assert has_element?(view, "#smtp-file-delivery-max_attachment_mb[value='1.000001']")
    assert Repo.reload!(config).settings == config.settings
    render_submit(view, "save", %{"email_config" => tabbed_smtp_params()})
    assert has_element?(view, "#save-status-ok")
  end

  test "SMTP rendering and persistence adapt to normalized declarations without granting support",
       %{conn: conn} do
    config = insert_smtp_channel(%{})
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.update!(channels, :email, &Map.put(&1, :bridge, DeclaredSmtpBridge))
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    assert has_element?(view, "#smtp-file-delivery-max_attachment_mb[min='1.000001'][max='2']")
    assert render(view) =~ "Attachment sending is unavailable"
    params = put_in(tabbed_smtp_params(), ["file_delivery", "max_attachment_mb"], "3")
    render_submit(view, "save", %{"email_config" => params})
    assert has_element?(view, "#smtp-settings-panel-advanced:not([hidden])")
    assert render(view) =~ "Must satisfy the declared numeric limit"
    assert Repo.reload!(config).settings == config.settings
    params = put_in(params, ["file_delivery", "max_attachment_mb"], "1.5")
    render_submit(view, "save", %{"email_config" => params})
    assert has_element?(view, "#save-status-ok")

    assert Repo.reload!(config).settings["file_delivery"] == %{
             "max_attachment_bytes" => 1_500_000,
             "send_on_file_failure" => false
           }

    {:ok, reloaded, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    assert has_element?(reloaded, "#smtp-file-delivery-max_attachment_mb[value='1.5'][max='2']")
  end

  test "SMTP untouched file controls ignore usage markers and still reject unknown settings", %{
    conn: conn
  } do
    config = insert_smtp_channel(%{})
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
    params = tabbed_smtp_params()

    params =
      update_in(params, ["file_delivery"], &Map.put(&1, "_unused_send_on_file_failure", ""))

    render_change(view, "validate", %{"email_config" => params})
    refute has_element?(view, "#smtp-settings-selector button", "Errors")

    render_submit(view, "save", %{
      "email_config" => put_in(params, ["file_delivery", "unexpected"], "true")
    })

    assert has_element?(
             view,
             "#smtp-settings-selector button[phx-value-tab=advanced][aria-pressed=true]",
             "Errors"
           )

    assert Repo.reload!(config).settings == config.settings

    render_submit(view, "save", %{"email_config" => params})
    assert has_element?(view, "#save-status-ok")

    assert Repo.reload!(config).settings["file_delivery"] == %{
             "max_attachment_bytes" => 1_000_001,
             "send_on_file_failure" => false
           }
  end

  describe "email capability display" do
    test "shared file controls save exact bytes and reload the selected SMTP connection", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")
      assert has_element?(view, "#smtp-file-delivery")
      assert render(view) =~ "Optional override"
      assert render(view) =~ "Attachment sending is unavailable"

      render_submit(view, "save", %{
        "email_config" => %{
          "relay" => "files.example.com",
          "from_email" => "files@example.com",
          "file_delivery" => %{
            "max_attachment_mb" => "1.000001",
            "max_encoded_message_mb" => "25",
            "max_attachments_per_message" => "4",
            "send_on_file_failure" => "false"
          }
        }
      })

      [saved] = ChannelConfig.list_by_provider("email:smtp")

      assert saved.settings["file_delivery"] == %{
               "max_attachment_bytes" => 1_000_001,
               "max_encoded_message_bytes" => 25_000_000,
               "max_attachments_per_message" => 4,
               "send_on_file_failure" => false
             }

      {:ok, reloaded, _} = live(conn, "/bo/channels/retrieval/email/smtp")

      assert has_element?(
               reloaded,
               "input[name='email_config[file_delivery][max_attachment_mb]'][value='1.000001']"
             )
    end

    test "malformed file settings render beside the field and do not save", %{conn: conn} do
      before = ChannelConfig.list_by_provider("email:smtp")
      {:ok, view, _} = live(conn, "/bo/channels/retrieval/email/smtp")

      render_change(view, "validate", %{
        "email_config" => %{
          "file_delivery" => %{"max_attachment_mb" => "0.0000001"}
        }
      })

      assert has_element?(view, "#smtp-file-delivery-max_attachment_mb-error")
      assert ChannelConfig.list_by_provider("email:smtp") == before

      render_change(view, "validate", %{"email_config" => %{"file_delivery" => "malformed"}})
      assert has_element?(view, "#smtp-file-delivery-error")
      assert ChannelConfig.list_by_provider("email:smtp") == before
    end

    for {transport, mode} <- [{"smtp", "none"}, {"imap", "imap_idle"}] do
      test "#{transport} uses the shared modal and appropriately scoped Channels endpoint", %{
        conn: conn
      } do
        :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
        transport = unquote(transport)
        provider = "email:" <> transport
        scope = if transport == "smtp", do: :configuration, else: :provider
        {:ok, view, _html} = live(conn, "/bo/channels/retrieval/email/" <> transport)

        assert_receive {:node_router_event,
                        %Event{
                          request: %{provider: ^provider, scope: ^scope} = request,
                          next_hop: %{destination: :channels},
                          opts: opts
                        }}

        assert opts[:action] == :channel_capability_snapshot

        if transport == "smtp",
          do: assert(request.config_id == ChannelConfig.get_any_by_provider(provider).id)

        assert has_element?(view, "[data-testid='channel-capabilities-trigger']")
        refute has_element?(view, "#capabilities-modal")

        view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()

        assert has_element?(
                 view,
                 "#capabilities-modal li",
                 "Mode: #{unquote(mode)}"
               )

        assert has_element?(view, "#capabilities-modal li.text-emerald-700", "Text")
        assert has_element?(view, "#capabilities-modal li.text-emerald-700", "Threads")
        refute has_element?(view, "#capabilities-modal li.text-emerald-700", "Streaming")

        refute has_element?(view, "#capabilities-modal li.text-emerald-700", "File")
        assert has_element?(view, "#capabilities-modal li", "File")
        refute render(view) =~ "receive only"
        refute render(view) =~ "send only"

        view |> element("[data-testid='channel-capabilities-close']") |> render_click()
        refute has_element?(view, "#capabilities-modal")
        assert has_element?(view, "button[phx-click='activate']", "Activate")
      end
    end

    test "SMTP capability display works before selecting one of multiple connectors", %{
      conn: conn
    } do
      for name <- ["Accounts", "Support"] do
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: name,
          provider: "email:smtp",
          kind: "retrieval",
          url: "smtp://configured-in-settings",
          token: "smtp-unused",
          enabled: false,
          settings: %{"relay" => "smtp.example.com"}
        })
        |> Repo.insert!()
      end

      {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
      refute has_element?(view, "#smtp-config-form")

      view |> element("[data-testid='channel-capabilities-trigger']") |> render_click()
      assert has_element?(view, "#capabilities-modal li", "Mode: none")
      refute has_element?(view, "#smtp-config-form")

      :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
      observe_capability_lookups()

      for {config, index} <- Enum.with_index(ChannelConfig.list_by_provider("email:smtp"), 1) do
        render_click(view, "select_connector", %{"id" => to_string(config.id)})
        config_id = config.id

        assert_receive {:node_router_event,
                        %Event{request: %{scope: :configuration, config_id: ^config_id}}}

        assert capability_lookup_count() == index

        render_change(view, "validate", %{
          "email_config" => %{"connector_name" => config.name <> " draft"}
        })

        render_click(view, "switch_settings_tab", %{"tab" => "advanced"})
        render_click(view, "open_capabilities")
        assert has_element?(view, "#capabilities-modal li", "Mode: none")

        assert has_element?(
                 view,
                 "input[name='email_config[connector_name]'][value='#{config.name} draft']"
               )

        assert capability_lookup_count() == index
        render_click(view, "close_capabilities")
      end
    end

    test "capability event handlers use only socket state" do
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:zaq, :repo, :query],
          fn _event, _measurements, metadata, {owner, view_pid} ->
            if self() == view_pid, do: send(owner, {:capability_database_query, metadata.query})
          end,
          {self(), self()}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for module <- [
            ZaqWeb.Live.BO.Communication.NotificationSmtpLive,
            ZaqWeb.Live.BO.Communication.NotificationImapLive
          ] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, capability_modal_open: false}
        }

        assert {:noreply, opened} = module.handle_event("open_capabilities", %{}, socket)
        assert opened.assigns.capability_modal_open
        assert {:noreply, closed} = module.handle_event("close_capabilities", %{}, opened)
        refute closed.assigns.capability_modal_open
      end

      refute_received {:capability_database_query, _query}
    end
  end

  test "mounts with defaults when no smtp config exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    assert has_element?(view, "#smtp-config-form")
    assert has_element?(view, "#test-email-form")
    assert has_element?(view, "button[phx-click='activate']", "Activate")
  end

  test "Add Config creates and selects a distinct named SMTP connector", %{conn: conn} do
    original =
      insert_smtp_channel(%{
        name: "Original",
        enabled: true,
        settings: %{"relay" => "original.example.com"}
      })

    original = Repo.get!(ChannelConfig, original.id)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    view |> element("#new-smtp-config") |> render_click()
    refute has_element?(view, "input[name='email_config[relay]'][value='original.example.com']")

    view
    |> element("#smtp-config-form")
    |> render_submit(%{
      "email_config" => %{
        "connector_name" => "Second SMTP",
        "relay" => "second.example.com",
        "from_email" => "second@example.com",
        "port" => "587"
      }
    })

    assert has_element?(view, "#save-status-ok")
    second = Repo.get_by!(ChannelConfig, name: "Second SMTP")
    assert second.id != original.id
    assert Repo.get!(ChannelConfig, original.id) == original

    view
    |> element("#smtp-config-form")
    |> render_submit(%{"email_config" => %{"relay" => "edited.example.com"}})

    assert Repo.get!(ChannelConfig, second.id).settings["relay"] == "edited.example.com"
    assert length(ChannelConfig.list_by_provider("email:smtp")) == 2
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

  test "two SMTP accounts require card selection and default is explicit", %{conn: conn} do
    first =
      insert_smtp_channel(%{
        name: "First SMTP",
        enabled: true,
        settings: %{"relay" => "first.example.com", "from_email" => "first@example.com"}
      })

    second =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Second SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        enabled: true,
        url: "smtp://configured-in-settings",
        token: "smtp-unused",
        settings: %{"relay" => "second.example.com", "from_email" => "second@example.com"}
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    assert has_element?(view, "#smtp-connector-#{first.id}")
    assert has_element?(view, "#smtp-connector-#{second.id}")
    refute has_element?(view, "#smtp-config-form")

    view
    |> element("#smtp-connector-#{second.id} [phx-click='select_connector']")
    |> render_click()

    assert has_element?(
             view,
             "#smtp-config-form input[name='email_config[relay]'][value='second.example.com']"
           )

    view |> element("#smtp-default-#{second.id}") |> render_click()
    assert Repo.get!(ChannelConfig, second.id).notification_default
    refute Repo.get!(ChannelConfig, first.id).notification_default
    assert has_element?(view, "#smtp-default-#{second.id}[aria-pressed='true']")
  end

  test "select_connector rejects an unknown id without changing the selected connector", %{
    conn: conn
  } do
    connector =
      insert_smtp_channel(%{
        name: "Selected SMTP",
        settings: %{"relay" => "selected.example.com"}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    render_click(view, "select_connector", %{"id" => "nonexistent"})

    assert render(view) =~ "Connector not found."

    assert has_element?(
             view,
             "#smtp-config-form input[name='email_config[relay]'][value='selected.example.com']"
           )

    assert Repo.get!(ChannelConfig, connector.id).settings["relay"] == "selected.example.com"
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

  test "save reports an archived selected connector without creating a replacement", %{
    conn: conn
  } do
    connector = insert_smtp_channel(%{name: "Stale SMTP"})
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    assert {:ok, _archived} = ChannelConfig.archive(Repo.get!(ChannelConfig, connector.id))

    view
    |> element("#smtp-config-form")
    |> render_submit(%{
      "email_config" => %{
        "relay" => "replacement.example.com",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "username" => "mailer@example.com",
        "password" => "no-persist-secret",
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      }
    })

    assert render(view) =~ "Failed to save email configuration."
    assert has_element?(view, "#save-status-error")
    assert {:error, ":connector_mismatch"} = current_save_status(view)
    assert Repo.get!(ChannelConfig, connector.id).settings["relay"] == "smtp.example.com"
    assert ChannelConfig.list_by_provider("email:smtp") == []
    refute Enum.any?(Repo.all(ChannelConfig), &(&1.settings["password"] == "no-persist-secret"))
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

  test "activate reports an archived selected connector", %{conn: conn} do
    connector = insert_smtp_channel(%{name: "Stale SMTP", enabled: true})
    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    assert {:ok, _archived} = ChannelConfig.archive(Repo.get!(ChannelConfig, connector.id))

    view |> element("button[phx-click='activate']") |> render_click()

    assert render(view) =~ "Failed to update email status."
    assert has_element?(view, "#save-status-error")
    assert {:error, ":connector_mismatch"} = current_save_status(view)
    assert ChannelConfig.list_by_provider("email:smtp") == []
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

  test "test_connection uses the outgoing email bridge with the saved SMTP settings", %{
    conn: conn
  } do
    insert_enabled_smtp_channel(%{"from_email" => "sender@example.com"})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert :ok = current_test_status(view)
    assert_receive {:smtp_send, "user@example.com", payload, %{}}
    assert payload["subject"] == "ZAQ — Email configuration test"
    assert payload["body"] =~ "This is a test email"
    assert render(view) =~ "Test email sent"
  end

  test "test_connection sends through the selected SMTP account rather than the default", %{
    conn: conn
  } do
    first = insert_enabled_smtp_channel(%{"from_email" => "default@example.com"})
    assert {:ok, _} = ChannelConfig.set_default_smtp_connector(first.id)

    second =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Selected SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        enabled: true,
        url: "smtp://configured-in-settings",
        token: "smtp-unused",
        settings: %{"relay" => "smtp.other.example", "from_email" => "selected@example.com"}
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view
    |> element("#smtp-connector-#{second.id} [phx-click='select_connector']")
    |> render_click()

    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert :ok = current_test_status(view)
    assert_receive {:smtp_send, "user@example.com", _, %{"smtp_config_id" => id}}
    assert id == second.id
    refute id == first.id
  end

  test "test_connection reaches the production SMTP sender", %{conn: conn} do
    insert_enabled_smtp_channel(%{"relay" => "127.0.0.1", "port" => "1"})
    Application.put_env(:zaq, :email_bridge_smtp_module, Zaq.Channels.EmailBridge.SmtpSender)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert {:error, message} = current_test_status(view)
    assert message =~ "Could not reach the SMTP server."
    assert render(view) =~ "Could not reach the SMTP server."
  end

  test "test_connection reports an adapter exit without crashing the page", %{conn: conn} do
    insert_enabled_smtp_channel()
    Application.put_env(:zaq, :smtp_live_test_result, :exit)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert {:error, "Email delivery failed unexpectedly. Check the server logs."} =
             current_test_status(view)

    assert render(view) =~ "Email delivery failed unexpectedly. Check the server logs."
  end

  test "test_connection reports an unexpected delivery response", %{conn: conn} do
    insert_enabled_smtp_channel()
    Application.put_env(:zaq, :smtp_live_test_result, :unexpected_receipt)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert {:error, "Email delivery returned an unexpected response."} = current_test_status(view)
    assert render(view) =~ "Email delivery returned an unexpected response."
    refute render(view) =~ "Test email sent"
  end

  test "test_connection reports a rescued sender exception and keeps the page alive", %{
    conn: conn
  } do
    insert_enabled_smtp_channel()
    Application.put_env(:zaq, :smtp_live_test_result, :raise)

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")

    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert {:error, "Safe SMTP sender failure"} = current_test_status(view)
    assert render(view) =~ "Safe SMTP sender failure"
    assert Process.alive?(view.pid)
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

  test "test_connection preserves empty retry detail without a Details label", %{conn: conn} do
    insert_enabled_smtp_channel()
    put_failing_mailer({:retries_exceeded, ""})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    send(view.pid, {:send_test, "user@example.com"})
    _ = :sys.get_state(view.pid)

    assert {:error, "Could not reach the SMTP server. "} = current_test_status(view)
    assert render(view) =~ "Could not reach the SMTP server."
    refute render(view) =~ "Details:"
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

  test "test_connection dispatches when optional TLS is selected", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
  end

  test "test_connection delegates password handling to the real email sender", %{conn: conn} do
    insert_enabled_smtp_channel(%{"password" => "enc:test-v1:not-b64:not-b64:not-b64"})
    put_failing_mailer({:network_failure, :econnrefused})

    {:ok, view, _html} = live(conn, ~p"/bo/channels/retrieval/email/smtp")
    view |> element("#test-email-form") |> render_submit(%{"recipient" => "user@example.com"})

    assert_receive {:smtp_send, "user@example.com", _, %{}}
    assert {:error, "Network error while contacting the SMTP server."} = current_test_status(view)
  end

  test "test_connection dispatches with no SMTP username", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
  end

  test "test_connection dispatches with verify_none configured", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
  end

  test "test_connection dispatches with required TLS and custom CA", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
  end

  test "test_connection dispatches with SSL transport", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
  end

  test "test_connection dispatches with an unknown TLS mode", %{conn: conn} do
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
    assert_receive {:smtp_send, "user@example.com", _, %{}}
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
        %{assigns: assigns} -> assigns
      end

    Map.fetch!(assigns, :test_status)
  end

  defp current_save_status(view) do
    state = :sys.get_state(view.pid)

    assigns =
      case state do
        %{socket: %{assigns: assigns}} -> assigns
        %{assigns: assigns} -> assigns
      end

    Map.fetch!(assigns, :save_status)
  end

  defp restore_env(key, nil), do: Application.delete_env(:zaq, key)
  defp restore_env(key, value), do: Application.put_env(:zaq, key, value)

  defp put_failing_mailer(reason) do
    previous_error = Application.get_env(:zaq, :smtp_live_test_error)
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

defmodule ZaqWeb.NotificationSmtpLiveTest.Sender do
  def send_notification(identifier, payload, metadata) do
    send(
      Application.fetch_env!(:zaq, :smtp_live_test_owner),
      {:smtp_send, identifier, payload, metadata}
    )

    case Application.get_env(:zaq, :smtp_live_test_result, :ok) do
      :exit ->
        exit(:noproc)

      :raise ->
        raise "Safe SMTP sender failure"

      result when result != :ok ->
        result

      :ok ->
        case Application.get_env(:zaq, :smtp_live_test_error) do
          nil -> :ok
          reason -> {:error, reason}
        end
    end
  end

  def send_notification(identifier, payload, metadata, config_id) do
    send_notification(identifier, payload, Map.put(metadata, "smtp_config_id", config_id))
  end
end
