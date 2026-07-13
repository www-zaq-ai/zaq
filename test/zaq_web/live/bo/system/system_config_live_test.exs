defmodule ZaqWeb.Live.BO.System.SystemConfigLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.MCP
  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.System

  defmodule MCPTestStub do
    def test_list_tools(_endpoint_id, _opts), do: {:ok, %{status: :ok}}
  end

  defmodule MCPTestNotReadyStub do
    def test_list_tools(_endpoint_id, _opts) do
      {:error,
       %{
         message: "Internal error",
         status: :error,
         type: :protocol,
         details: "Server capabilities not set"
       }}
    end
  end

  defmodule MCPTestUnauthorizedStub do
    def test_list_tools(_endpoint_id, _opts) do
      {:error,
       %{
         message: "Send Failure",
         status: :error,
         type: :transport,
         details:
           "{:http_error, 401, \"unauthorized: unauthorized: AuthenticateToken authentication failed\\n\"}"
       }}
    end
  end

  defmodule MCPTestOtherResponseStub do
    def test_list_tools(_endpoint_id, _opts), do: :unexpected
  end

  defmodule MCPTestAlreadyRegisteredStub do
    def test_list_tools(_endpoint_id, _opts), do: {:error, :endpoint_already_registered}
  end

  defmodule MCPTestRuntimeExitStub do
    def test_list_tools(_endpoint_id, _opts),
      do: {:error, {:mcp_runtime_call_exit, {:shutdown, :noproc}}}
  end

  defmodule MCPTestGenericErrorStub do
    def test_list_tools(_endpoint_id, _opts),
      do: {:error, :generic_failure}
  end

  defmodule OldGlobalNodeRouterLeakStub do
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{email: "admin@example.com", username: "testadmin_sc"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  describe "mount" do
    test "renders ai credentials by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/system-config")
      assert html =~ "AI Credentials"
    end

    test "does not render global default agent selector in ai credentials tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      refute has_element?(view, "#global-default-agent-select")
    end
  end

  describe "tab navigation" do
    test "falls back to ai credentials for unknown tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/system-config?tab=unknown")
      assert html =~ "AI Credentials"
      refute html =~ "llm-config-form"
    end

    test "switches to AI credentials tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='ai_credentials']")
      |> render_click()

      assert_patch(view, ~p"/bo/system-config?tab=ai_credentials")
      assert has_element?(view, "#ai-credential-form", "") == false
      assert render(view) =~ "AI Credentials"
    end

    test "switches to Global tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='global']")
      |> render_click()

      assert_patch(view, ~p"/bo/system-config?tab=global")
      assert has_element?(view, "#global-default-agent-select")
      assert render(view) =~ "Default Zaq Agent"
    end

    test "renders each tab via URL param", %{conn: conn} do
      {:ok, _view, telemetry_html} = live(conn, ~p"/bo/system-config?tab=telemetry")
      assert telemetry_html =~ "telemetry-config-form"

      {:ok, _view, llm_html} = live(conn, ~p"/bo/system-config?tab=llm")
      assert llm_html =~ "llm-config-form"

      {:ok, _view, embedding_html} = live(conn, ~p"/bo/system-config?tab=embedding")
      assert embedding_html =~ "embedding-config-form"

      {:ok, _view, image_to_text_html} = live(conn, ~p"/bo/system-config?tab=image_to_text")
      assert image_to_text_html =~ "image-to-text-config-form"

      {:ok, _view, ai_credentials_html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")
      assert ai_credentials_html =~ "AI Credentials"

      {:ok, _view, mcp_html} = live(conn, ~p"/bo/system-config?tab=mcps")
      assert mcp_html =~ "MCP Administration"

      {:ok, _view, global_html} = live(conn, ~p"/bo/system-config?tab=global")
      assert global_html =~ "Global"
      assert global_html =~ "Default Zaq Agent"
    end
  end

  describe "MCP administration" do
    setup do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      :ok
    end

    test "switches to MCP tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='mcps']")
      |> render_click()

      assert_patch(view, ~p"/bo/system-config?tab=mcps")
      assert render(view) =~ "MCP Administration"
    end

    test "creates MCP endpoint from modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Remote MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "X-App", "value" => "zaq"}},
            "secret_headers_rows" => %{
              "0" => %{"key" => "Authorization", "value" => "Bearer test"}
            },
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved"

      {entries, _total} =
        MCP.filter_mcp_endpoints(%{"name" => "Remote MCP"}, page: 1, per_page: 10)

      endpoint = Enum.find(entries, &(&1.name == "Remote MCP"))
      assert endpoint
      assert endpoint.headers["X-App"] == "zaq"
      assert is_binary(endpoint.secret_headers["Authorization"])
      refute endpoint.secret_headers["Authorization"] == "Bearer test"
    end

    test "MCP modal toggles local and remote fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[command]']")
      refute has_element?(view, "input[name='mcp_endpoint[url]']")
      assert has_element?(view, "input[name='mcp_endpoint[args_rows][0][value]']")
      refute has_element?(view, "input[name='mcp_endpoint[headers_rows][0][key]']")
      assert render(view) =~ "max-h-[90vh]"

      assert has_element?(
               view,
               "button[aria-label='Remove row'][phx-value-collection='args'][class*='text-red-500']"
             )

      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Remote Draft",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:9000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "1"}},
          "secret_headers_rows" => %{"0" => %{"key" => "Authorization", "value" => "Bearer x"}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      assert has_element?(view, "input[name='mcp_endpoint[url]']")
      refute has_element?(view, "input[name='mcp_endpoint[command]']")
      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][0][key]']")
      assert has_element?(view, "input[name='mcp_endpoint[secret_headers_rows][0][value]']")
      refute has_element?(view, "input[name='mcp_endpoint[args_rows][0][value]']")

      assert has_element?(
               view,
               "button[aria-label='Remove row'][phx-value-collection='headers'][class*='text-red-500']"
             )
    end

    test "adds and removes remote header rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Remote Draft",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:9000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "1"}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][0][key]']")
      refute has_element?(view, "input[name='mcp_endpoint[headers_rows][1][key]']")

      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='headers']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][1][key]']")

      view
      |> element(
        "button[phx-click='remove_mcp_row'][phx-value-collection='headers'][phx-value-index='1']"
      )
      |> render_click()

      refute has_element?(view, "input[name='mcp_endpoint[headers_rows][1][key]']")
      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][0][key]']")
    end

    test "edit modal shows previously saved secret values", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Remote Secret MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp",
          secret_headers: %{"Authorization" => "Bearer persisted"},
          secret_environments: %{"API_TOKEN" => "token-persisted"}
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      assert has_element?(
               view,
               "input[name='mcp_endpoint[secret_headers_rows][0][value]'][value='Bearer persisted']"
             )
    end

    test "tests MCP endpoint through NodeRouter action", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Testable MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test succeeded."
      refute has_element?(view, "#mcp-test-button-#{endpoint.id}[disabled]")
    end

    test "shows friendly message when MCP server capabilities are not ready", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestNotReadyStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Not Ready MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test failed: server handshake not ready yet"
    end

    test "shows friendly unauthorized message when MCP authentication fails", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestUnauthorizedStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Unauthorized MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test failed: unauthorized (401)."
      refute has_element?(view, "#mcp-test-button-#{endpoint.id}[disabled]")
    end

    test "filters MCP endpoints by name and resets page", %{conn: conn} do
      assert {:ok, _} =
               MCP.create_mcp_endpoint(%{
                 name: "Filterable Endpoint",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        render_change(view, "filter_mcp_endpoints", %{
          "mcp_filter_name" => "filterable",
          "mcp_filter_type" => "all",
          "mcp_filter_status" => "all"
        })

      assert html =~ "Filterable Endpoint"
    end

    test "close_mcp_endpoint_modal hides modal after opening", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      assert has_element?(view, "#mcp-endpoint-modal")

      render_click(view, "close_mcp_endpoint_modal", %{})
      refute has_element?(view, "#mcp-endpoint-modal")
    end

    test "open/cancel delete confirm toggles MCP delete modal", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Delete Toggle MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      refute has_element?(view, "#mcp-endpoint-delete-confirm")

      render_click(view, "open_delete_mcp_endpoint_confirm", %{})
      assert has_element?(view, "#mcp-endpoint-delete-confirm")

      render_click(view, "cancel_delete_mcp_endpoint", %{})
      refute has_element?(view, "#mcp-endpoint-delete-confirm")
    end

    test "changes MCP page with valid and invalid values", %{conn: conn} do
      {:ok, _} =
        MCP.create_mcp_endpoint(%{
          name: "Paging MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "change_mcp_page", %{"page" => "2"})
      assert html =~ "MCP Administration"

      html = render_click(view, "change_mcp_page", %{"page" => "not-a-number"})
      assert html =~ "MCP Administration"
    end

    test "saves MCP endpoint in edit mode", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Editable MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Editable MCP Updated",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "6000",
            "url" => "http://localhost:9000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved"
      assert MCP.get_mcp_endpoint!(endpoint.id).name == "Editable MCP Updated"
    end

    test "save MCP endpoint shows validation errors on invalid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "0",
            "url" => "",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP Administration"
      assert has_element?(view, "#mcp-endpoint-modal")
    end

    test "enable predefined MCP opens edit modal for editable predefined endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "enable_predefined_mcp", %{"predefined_id" => "github_mcp"})

      assert html =~ "Predefined MCP enabled."
      assert has_element?(view, "#mcp-endpoint-modal")
      assert has_element?(view, "input[name='mcp_endpoint[name]']")
    end

    test "confirm delete MCP endpoint removes endpoint", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Delete Me MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      render_click(view, "open_delete_mcp_endpoint_confirm", %{})
      html = render_click(view, "confirm_delete_mcp_endpoint", %{})

      assert html =~ "MCP endpoint deleted"
      assert_raise Ecto.NoResultsError, fn -> MCP.get_mcp_endpoint!(endpoint.id) end
    end

    test "enable predefined mcp failure shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "enable_predefined_mcp", %{"predefined_id" => "unknown"})
      assert html =~ "Failed to enable MCP"
    end

    test "shows fallback message for unexpected MCP test response", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestOtherResponseStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Other Response MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test returned"
    end

    test "shows stale-endpoint message when endpoint already registered", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestAlreadyRegisteredStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Already Registered MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "stale test endpoint state detected"
    end

    test "shows client-disconnect message for mcp runtime call exit", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestRuntimeExitStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Runtime Exit MCP",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP client disconnected during request"
    end
  end

  describe "telemetry config" do
    test "validate_telemetry assigns validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_change(view, "validate_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "-1",
            "repo_query_duration_threshold_ms" => "-1",
            "no_answer_alert_threshold_percent" => "101",
            "conversation_response_sla_ms" => "-1"
          }
        })

      assert html =~ "telemetry-config-form"
    end

    test "save_telemetry with invalid params keeps form in validation mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_submit(view, "save_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "-1",
            "repo_query_duration_threshold_ms" => "-1",
            "no_answer_alert_threshold_percent" => "120",
            "conversation_response_sla_ms" => "-1"
          }
        })

      refute html =~ "Telemetry settings saved."
      assert html =~ "telemetry-config-form"
    end

    test "save_telemetry with valid params shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_submit(view, "save_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "25",
            "repo_query_duration_threshold_ms" => "10",
            "no_answer_alert_threshold_percent" => "12",
            "conversation_response_sla_ms" => "1600"
          }
        })

      assert html =~ "Telemetry settings saved."
    end
  end

  describe "AI credentials modal and validation" do
    test "api key field has show/hide eye controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(
               view,
               "#ai-credential-api-key-input[style*='-webkit-text-security: disc']"
             )

      assert has_element?(view, "#ai-credential-api-key-show")
      assert has_element?(view, "#ai-credential-api-key-hide.hidden")
    end

    test "provider selector includes ReqLLM-only OpenAI Codex provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html = render(view)

      assert html =~ "OpenAI Codex"
      assert html =~ "openai_codex"
    end

    test "provider selector hides unsupported LLMDB providers by default", %{conn: conn} do
      previous = Application.get_env(:zaq, :show_unsupported_ai_providers)
      Application.put_env(:zaq, :show_unsupported_ai_providers, false)
      on_exit(fn -> restore_show_unsupported_ai_providers(previous) end)

      case unsupported_llmdb_provider_option() do
        nil ->
          :ok

        {label, provider_id} ->
          {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

          view
          |> element("button[phx-click='new_ai_credential']")
          |> render_click()

          html = render(view)
          refute html =~ label
          refute html =~ provider_id
      end
    end

    test "provider selector can show unsupported LLMDB providers as disabled", %{conn: conn} do
      previous = Application.get_env(:zaq, :show_unsupported_ai_providers)
      Application.put_env(:zaq, :show_unsupported_ai_providers, true)
      on_exit(fn -> restore_show_unsupported_ai_providers(previous) end)

      case unsupported_llmdb_provider_option() do
        nil ->
          :ok

        {label, provider_id} ->
          {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

          view
          |> element("button[phx-click='new_ai_credential']")
          |> render_click()

          html = render(view)
          assert html =~ label
          assert html =~ provider_id
          assert html =~ "unsupported"
          assert html =~ ~s(data-select-disabled="true")
      end
    end

    test "creates new credential from modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")

      render_submit(view, "save_ai_credential", %{
        "ai_credential" => %{
          "name" => "OpenAI EU",
          "provider" => "openai",
          "endpoint" => "https://api.openai.com/v1",
          "api_key" => "sk-test-live",
          "sovereign" => "true",
          "description" => "EU sovereign"
        }
      })

      assert render(view) =~ "AI credential saved."
      assert render(view) =~ "OpenAI EU"
    end

    test "creates OpenAI Codex credential as OAuth2 only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      render_submit(view, "save_ai_credential", %{
        "ai_credential" => %{
          "name" => "Codex Subscription",
          "provider" => "openai_codex",
          "endpoint" => "https://chatgpt.com/backend-api",
          "auth_mode" => "api_key",
          "api_key" => "ignored-key",
          "metadata" => "{}"
        }
      })

      assert render(view) =~ "AI credential saved."

      credential = System.get_ai_provider_credential_by_name("Codex Subscription")
      assert credential.provider == "openai_codex"
      assert credential.api_key in [nil, ""]
      assert credential.metadata["auth_kind"] == "oauth2"
      assert credential.metadata["auth_profile"] == "openai_chatgpt_codex"
    end

    test "editing row opens modal", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "Primary",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          description: "main"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      assert has_element?(view, "#oauth-popup-listener[phx-hook='OAuthPopupListener']")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")
      assert render(view) =~ "Edit AI Credential"
      assert render(view) =~ "Primary"
    end

    test "connect_ai_credential_oauth creates backing Connect credential and opens popup", %{
      conn: conn
    } do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Codex OAuth",
          provider: "openai_codex",
          endpoint: "https://chatgpt.com/backend-api",
          metadata: %{
            "auth_kind" => "oauth2",
            "auth_profile" => "openai_chatgpt_codex",
            "authorize_url" => "https://auth.openai.com/oauth/authorize",
            "token_url" => "https://auth.openai.com/oauth/token",
            "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
            "scope" => "openid profile email offline_access",
            "authorize_params" => %{"originator" => "zaqos"}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click='connect_ai_credential_oauth'][phx-value-id='#{credential.id}']"
      )
      |> render_click()

      connect_credential =
        Connect.list_credentials()
        |> Enum.find(fn connect_credential ->
          connect_credential.metadata["ai_provider_credential_id"] == to_string(credential.id)
        end)

      assert credential.provider == "openai_codex"
      assert connect_credential.provider == "openai"
      assert connect_credential.auth_kind == "oauth2"
      assert connect_credential.client_id == "app_EMoamEEZ73f0CkXaXp7hrann"

      assert connect_credential.metadata["authorize_params"]["id_token_add_organizations"] ==
               "true"

      assert connect_credential.metadata["authorize_params"]["codex_cli_simplified_flow"] ==
               "true"

      assert_push_event(view, "open_oauth_popup", %{url: url})
      assert url =~ "https://auth.openai.com/oauth/authorize"

      assert url =~
               "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"

      assert url =~ "originator=zaqos"
      assert url =~ "id_token_add_organizations=true"
      assert url =~ "codex_cli_simplified_flow=true"
      assert url =~ "code_challenge_method=S256"
    end

    test "deletes an unused credential from edit modal with confirmation", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Disposable",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      assert has_element?(view, "#ai-credential-delete-confirm")

      view
      |> element("button[phx-click='confirm_delete_ai_credential']")
      |> render_click()

      assert render(view) =~ "AI credential deleted."
      refute render(view) =~ "Disposable"
    end

    test "cannot delete credential currently in use", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "In Use",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      System.set_config("llm.credential_id", credential.id)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_delete_ai_credential']")
      |> render_click()

      assert render(view) =~ "cannot delete credential currently used by system configuration"

      id = credential.id
      assert %Zaq.System.AIProviderCredential{id: ^id} = System.get_ai_provider_credential!(id)
    end
  end

  describe "LLM config with credential" do
    test "saves llm config using selected credential", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "LLM Credential",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      render_submit(view, "save_llm", %{
        "llm_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "gpt-4o",
          "temperature" => "0.2",
          "top_p" => "0.9",
          "supports_logprobs" => "true",
          "supports_json_mode" => "true",
          "max_context_window" => "5000",
          "distance_threshold" => "1.0",
          "path" => "/chat/completions"
        }
      })

      cfg = System.get_llm_config()
      assert cfg.credential_id == credential.id
      assert cfg.provider == "openai"
      assert cfg.endpoint == "https://api.openai.com/v1"
      assert cfg.model == "gpt-4o"
    end

    test "save_llm with invalid params renders errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_submit(view, "save_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "",
            "temperature" => "3.0",
            "top_p" => "2.0",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "0",
            "distance_threshold" => "0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
      refute html =~ "LLM settings saved."
    end

    test "validate_llm updates form state when switching credential", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI LLM",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
      assert has_element?(view, "#llm-credential-select")
      assert html =~ "GPT-4o"
    end

    test "validate_llm lists ReqLLM-only Codex models and path metadata", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Codex LLM",
          provider: "openai_codex",
          endpoint: "https://chatgpt.com/backend-api"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-5.3-codex-spark",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "GPT-5.3 Codex Spark"
      assert html =~ ~s(data-select-value="gpt-5.3-codex-spark")
      assert html =~ ~s(name="llm_config[path]" value="/responses")
    end

    test "validate_llm keeps capabilities when provider and model are unchanged", %{conn: conn} do
      credential =
        seed_llm_config(%{
          model: "steady-llm-model",
          temperature: 0.1,
          top_p: 0.8,
          supports_logprobs: true,
          supports_json_mode: true
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "steady-llm-model",
            "temperature" => "0.1",
            "top_p" => "0.8",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.2",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles unknown provider by falling back safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Provider",
          provider: "provider-not-in-lldb",
          endpoint: "https://example.invalid/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "unknown-model",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles missing credential id safely", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "999999999",
            "model" => "",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles switch to custom provider path", %{conn: conn} do
      credential =
        seed_llm_config(%{
          model: "switchable-model",
          temperature: 0.1,
          top_p: 0.8
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "",
            "temperature" => "0.1",
            "top_p" => "0.8",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.2",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
      assert System.get_llm_config().credential_id == credential.id
    end

    test "validate_llm handles unknown model capabilities fallback", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Unknown Model",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "model-not-in-lldb",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles empty or missing model values safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Empty Model",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html_empty =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      html_missing =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html_empty =~ "llm-config-form"
      assert html_missing =~ "llm-config-form"
    end
  end

  describe "embedding save confirmation" do
    test "save_embedding opens and cancel closes destructive confirmation modal", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "Embedding Credential",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_unlock_embedding']")
      |> render_click()

      params = %{
        "embedding_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "different-model",
          "dimension" => "3584",
          "chunk_min_tokens" => "400",
          "chunk_max_tokens" => "900"
        }
      }

      _ = render_change(view, "validate_embedding", params)

      html = render_submit(view, "save_embedding", params)

      assert html =~ "Delete All Embeddings?"

      html =
        view
        |> element("button[phx-click='cancel_save_embedding']")
        |> render_click()

      refute html =~ "Delete All Embeddings?"
    end

    test "unlock modal can be opened and closed without unlocking", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        view
        |> element("button[phx-click='unlock_embedding']")
        |> render_click()

      assert html =~ "Unlock Model Selection"

      html =
        view
        |> element("button[phx-click='cancel_unlock_embedding']")
        |> render_click()

      refute html =~ "Unlock Model Selection"
      assert html =~ "Locked"
    end

    test "confirm unlock removes locked state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='confirm_unlock_embedding']")
        |> render_click()

      refute html =~ "Unlock Model Selection"
      refute html =~ "Locked"
    end

    test "confirm save embedding applies pending params", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Embedding Pending",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_unlock_embedding']")
      |> render_click()

      params = %{
        "embedding_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "different-model-for-confirm",
          "dimension" => "3584",
          "chunk_min_tokens" => "400",
          "chunk_max_tokens" => "900"
        }
      }

      _ = render_change(view, "validate_embedding", params)
      _ = render_submit(view, "save_embedding", params)

      html =
        view
        |> element("button[phx-click='confirm_save_embedding']")
        |> render_click()

      refute html =~ "Delete All Embeddings?"
      assert html =~ "Embedding settings saved."
    end

    test "save embedding without model change does not open confirmation modal", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "seed-embedding-model",
          dimension: 1536,
          chunk_min_tokens: 300,
          chunk_max_tokens: 700
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      params = %{
        "embedding_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "seed-embedding-model",
          "dimension" => "1536",
          "chunk_min_tokens" => "320",
          "chunk_max_tokens" => "720"
        }
      }

      html = render_submit(view, "save_embedding", params)

      refute html =~ "Delete All Embeddings?"
      assert html =~ "Embedding settings saved."
    end

    test "save embedding invalid params renders embedding errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_submit(view, "save_embedding", %{
          "embedding_config" => %{
            "credential_id" => "",
            "model" => "",
            "dimension" => "0",
            "chunk_min_tokens" => "0",
            "chunk_max_tokens" => "0"
          }
        })

      assert html =~ "embedding-config-form"
      refute html =~ "Embedding settings saved."
    end

    test "confirm_save_embedding rescues when pending params are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html = render_click(view, "confirm_save_embedding", %{})

      assert html =~ "Failed to apply embedding settings"
    end

    test "validate_embedding handles unknown provider safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Embedding Provider",
          provider: "provider-not-in-lldb",
          endpoint: "https://example.invalid/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "unknown-model",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding lists embedding-capable OpenAI catalog models for Codex", %{
      conn: conn
    } do
      credential =
        ai_credential_fixture(%{
          name: "Codex Embedding",
          provider: "openai_codex",
          endpoint: "https://chatgpt.com/backend-api"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
      assert html =~ ~s(data-select-value="text-embedding-3-small")
      assert html =~ ~s(id="embedding-model-select")
      refute html =~ "GPT-5.3 Codex Spark"
    end

    test "validate_embedding handles blank model dimension lookup", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "baseline-embedding-model",
          dimension: 1536
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding flags model_changed when only dimension changes", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "stable-embedding-model",
          dimension: 1536,
          chunk_min_tokens: 300,
          chunk_max_tokens: 700
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "stable-embedding-model",
            "dimension" => "1600",
            "chunk_min_tokens" => "300",
            "chunk_max_tokens" => "700"
          }
        })

      assert html =~ "bg-red-500"
    end
  end

  describe "image to text config" do
    test "save_image_to_text with invalid params renders errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => "",
            "model" => ""
          }
        })

      assert html =~ "image-to-text-config-form"
      refute html =~ "Image-to-Text settings saved."
    end

    test "validate_image_to_text updates form state", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Vision Provider",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_change(view, "validate_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o"
          }
        })

      assert html =~ "image-to-text-config-form"
      assert has_element?(view, "#image-to-text-credential-select")
    end

    test "validate_image_to_text lists image-capable Codex models", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Codex Vision",
          provider: "openai_codex",
          endpoint: "https://chatgpt.com/backend-api"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_change(view, "validate_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => ""
          }
        })

      assert html =~ "image-to-text-config-form"
      assert html =~ "GPT-5.3 Codex Spark"
      assert html =~ ~s(data-select-value="gpt-5.3-codex-spark")
      assert html =~ ~s(id="image-to-text-model-select")
    end

    test "save_image_to_text with valid params shows success flash", %{conn: conn} do
      credential =
        seed_image_to_text_config(%{
          model: "vision-seed-model"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o"
          }
        })

      assert html =~ "Image-to-Text settings saved."
    end
  end

  describe "AI credentials" do
    test "close_ai_credential_modal hides modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")

      html =
        view
        |> element("button.zaq-btn[phx-click='close_ai_credential_modal']")
        |> render_click()

      refute html =~ "ai-credential-form"
    end

    test "validate_ai_credential auto-fills endpoint when provider changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Custom Cred",
            "provider" => "custom",
            "endpoint" => "https://will-be-overridden.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential keeps endpoint when provider is unchanged", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      _ =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Stable Cred",
            "provider" => "custom",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Stable Cred",
            "provider" => "custom",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential uses provider fallback endpoint for unknown atom-backed provider",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Unknown Atom Provider Cred",
            "provider" => "elixir",
            "endpoint" => "https://previous-endpoint.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential handles unknown provider fallback endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Unknown Provider Cred",
            "provider" => "provider-not-in-lldb",
            "endpoint" => "https://previous-endpoint.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "save_ai_credential invalid params keeps modal open", %{conn: conn} do
      original_node_router = Application.get_env(:zaq, :node_router_module)

      Application.put_env(
        :zaq,
        :node_router_module,
        ZaqWeb.Live.BO.System.SystemConfigLiveTest.OldGlobalNodeRouterLeakStub
      )

      on_exit(fn ->
        if original_node_router,
          do: Application.put_env(:zaq, :node_router_module, original_node_router),
          else: Application.delete_env(:zaq, :node_router_module)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "",
            "provider" => "",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ "ai-credential-form"
      refute html =~ "AI credential saved."
    end

    test "save_ai_credential updates an existing credential", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Editable Cred",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "Editable Cred Updated",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v2",
            "api_key" => "",
            "sovereign" => "false",
            "description" => "updated"
          }
        })

      assert html =~ "AI credential saved."
      assert render(view) =~ "Editable Cred Updated"
    end

    test "validate_ai_credential in edit mode resolves credential for action", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Validate Edit Cred",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Validate Edit Cred",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "",
            "sovereign" => "true",
            "description" => "edit validation"
          }
        })

      assert html =~ "ai-credential-form"
    end

    test "save_ai_credential shows encryption error when key config is invalid", %{conn: conn} do
      prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "Encryption Fail Cred",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "must-fail",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ "could not be encrypted"
      assert html =~ "ai-credential-form"
    end

    test "cancel_delete_ai_credential closes the confirm modal", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "To Cancel Delete",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      assert has_element?(view, "#ai-credential-delete-confirm")

      view
      |> element("button[phx-click='cancel_delete_ai_credential']")
      |> render_click()

      refute has_element?(view, "#ai-credential-delete-confirm")
    end

    test "edit_ai_credential with missing id raises Ecto.NoResultsError", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_ai_provider_credential_bang ->
            %Zaq.Event{event | response: {:error, :not_found}}

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      previous = Process.flag(:trap_exit, true)
      task = Task.async(fn -> render_click(view, "edit_ai_credential", %{"id" => "99999999"}) end)
      task_pid = task.pid

      assert_receive {:DOWN, _ref, :process, ^task_pid, _reason}
      Process.flag(:trap_exit, previous)
    end
  end

  describe "LLM fusion weight controls" do
    test "validate_llm adjusts bm25_weight when vector_weight changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.7"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm passes params unchanged when no weight changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles non-numeric fusion weight gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "notanumber",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "save_llm shows error when fusion weights sum is below minimum", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "LLM Fusion Weights",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_submit(view, "save_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.04",
            "fusion_vector_weight" => "0.05"
          }
        })

      assert html =~ "combined fusion weights must sum to at least 0.1"
    end

    test "validate_llm uses custom path when switching to no-credential", %{conn: conn} do
      _credential = seed_llm_config(%{model: "switchable-for-custom"})

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "switchable-for-custom",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles non-integer credential_id string as custom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "not-a-number",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm clamps float fusion weight inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => 0.75,
            "fusion_vector_weight" => 0.25
          }
        })

      assert html =~ ~s(name="llm_config[fusion_bm25_weight]" value="0.75")
      assert html =~ ~s(name="llm_config[fusion_vector_weight]" value="0.25")
    end

    test "validate_llm treats non-map credential ids as custom providers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => %{},
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end
  end

  describe "embedding dimension detection" do
    test "validate_embedding with custom provider sets no dimension", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => "",
            "model" => "text-embedding-3-small",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding with unknown provider handles ArgumentError", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Provider Embedding",
          provider: "totally-unknown-provider",
          endpoint: "https://unknown.example/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "some-model",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding fills default and max dimensions for known OpenAI models", %{
      conn: conn
    } do
      credential =
        ai_credential_fixture(%{
          name: "Known Embedding Provider",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      _html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "model-not-in-lldb",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      html_small =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "text-embedding-3-small",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html_small =~ ~s(name="embedding_config[dimension]" value="1536")

      html_large =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "text-embedding-3-large",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html_large =~ ~s(name="embedding_config[dimension]" value="3072")
    end

    test "validate_embedding keeps dimension when lookup returns nil", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Model Embedding",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      _html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "model-not-in-lldb",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      _html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "text-embedding-3-small",
            "dimension" => "1536",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "model-not-in-lldb",
            "dimension" => "1536",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ ~s(name="embedding_config[dimension]" value="1536")
    end
  end

  describe "image-to-text form validation" do
    test "save_image_to_text with invalid params renders form errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => "",
            "model" => ""
          }
        })

      assert html =~ "image-to-text-config-form"
      refute html =~ "Image-to-Text settings saved."
    end
  end

  describe "global default agent saving" do
    test "accepts empty global_default_agent_id and saves", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_default_agent", %{
          "global_default_agent_id" => ""
        })

      assert html =~ "Global default agent saved."
    end

    test "accepts numeric global_default_agent_id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_default_agent", %{
          "global_default_agent_id" => "99999999"
        })

      assert html =~ "Global default agent saved."
    end
  end

  describe "global base URL saving" do
    test "saves configured global base URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_base_url", %{
          "global_base_url" => "https://zaq.example"
        })

      assert html =~ "Global base URL saved."
      assert Zaq.System.get_global_base_url() == "https://zaq.example"
    end
  end

  describe "MCP test endpoint failure mapping" do
    test "shows generic fallback message for unexpected MCP error", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestOtherResponseStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Fallback MCP #{:erlang.unique_integer([:positive])}",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test returned"
    end

    test "shows generic fallback message for unknown mcp error", %{conn: conn} do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestGenericErrorStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Generic Fail MCP #{:erlang.unique_integer([:positive])}",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html =
        view
        |> element("#mcp-test-button-#{endpoint.id}")
        |> render_click()

      assert html =~ "MCP tools test failed"
    end

    test "save MCP endpoint with empty settings text falls back to empty map", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Settings Empty Test",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => ""
          }
        })

      assert html =~ "MCP endpoint saved"
    end

    test "save MCP endpoint with invalid settings JSON falls back to empty map", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Settings Invalid JSON",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "not-valid-json-content"
          }
        })

      assert html =~ "MCP endpoint saved"
    end

    test "validate MCP endpoint with unknown type exercises apply_mcp_type_scope catch-all",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_change(view, "validate_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Unknown Type Draft",
            "type" => "hybrid",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "1"}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP Administration"
      assert html =~ "Unknown Type Draft"
    end

    test "save MCP endpoint with empty args rows falls back to blank row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Args Empty",
            "type" => "local",
            "status" => "disabled",
            "timeout_ms" => "5000",
            "url" => "",
            "command" => "echo",
            "predefined_id" => "",
            "headers_rows" => %{},
            "secret_headers_rows" => %{},
            "args_rows" => %{},
            "environments_rows" => %{},
            "secret_environments_rows" => %{},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved"
    end

    test "save MCP endpoint validation error preserves changeset fields and rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      render_submit(view, "save_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "0",
          "url" => "",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "val"}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => "test-arg"}},
          "environments_rows" => %{"0" => %{"key" => "ENV_VAR", "value" => "env_val"}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      assert has_element?(view, "#mcp-endpoint-modal")
    end

    test "save MCP endpoint with blank optional fields uses nil defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Optional Fields MCP",
            "type" => "local",
            "status" => "disabled",
            "timeout_ms" => "5000",
            "command" => "echo",
            "url" => "",
            "predefined_id" => "",
            "args_rows" => %{},
            "headers_rows" => %{},
            "secret_headers_rows" => %{},
            "environments_rows" => %{},
            "secret_environments_rows" => %{},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved"
    end

    test "local MCP endpoint edit shows command and hides url/headers", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Local MCP Edit",
          type: "local",
          status: "disabled",
          timeout_ms: 5000,
          command: "echo hello"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[command]']")
      refute has_element?(view, "input[name='mcp_endpoint[url]']")
    end
  end

  describe "connect grants modal" do
    test "edits connect credential from auth credentials tab", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert has_element?(view, "#edit-connect-credential-modal")

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Credential Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid-updated",
            "client_secret" => "",
            "scopes" => "scope.read, scope.write\nscope.admin"
          }
        })

      assert html =~ "Credential updated."
      assert html =~ "Credential Updated"

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.scopes == ["scope.read", "scope.write", "scope.admin"]
    end

    test "shows expired status, allows erase, and queues manual refresh", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret",
          token_url: "https://oauth.example/token",
          scopes: ["scope.read"]
        })

      {:ok, expired_grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "123",
          owner_type: "org",
          owner_id: 1,
          request_format: "bearer",
          status: "active",
          access_token: "access-expired",
          refresh_token: "refresh-expired",
          scopes: ["scope.read"],
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, refreshable_grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "456",
          owner_type: "org",
          owner_id: 1,
          request_format: "bearer",
          status: "active",
          access_token: "access-live",
          refresh_token: "refresh-live",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      html =
        view
        |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
        |> render_click()

      assert html =~ "Grants — #{credential.name}"
      assert html =~ "bg-red-500"
      assert html =~ "scopes: scope.read"

      html =
        view
        |> element(
          "button[phx-click='trigger_connect_grant_refresh'][phx-value-id='#{refreshable_grant.id}']"
        )
        |> render_click()

      assert html =~ "Grant refresh queued."

      html =
        view
        |> element("button[phx-click='delete_connect_grant'][phx-value-id='#{expired_grant.id}']")
        |> render_click()

      assert html =~ "Grant erased."
      refute Repo.get(Zaq.Engine.Connect.Grant, expired_grant.id)
    end

    test "handles missing connect credential and missing grant ids", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      html = render_click(view, "edit_connect_credential", %{"id" => "99999999"})
      assert html =~ "Credential not found."

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      html = render_click(view, "trigger_connect_grant_refresh", %{"id" => "99999999"})
      assert html =~ "Grant not found."

      html = render_click(view, "delete_connect_grant", %{"id" => "99999998"})
      assert html =~ "Grant not found."
    end

    test "validates and keeps credential modal open when data is invalid", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_change(view, "validate_connect_credential", %{
          "credential" => %{
            "name" => "",
            "provider" => "attempted-overwrite",
            "request_format" => "raw",
            "auth_kind" => "oauth2",
            "client_id" => ""
          }
        })

      assert has_element?(view, "#edit-connect-credential-modal")
      refute html =~ "Credential updated."

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "",
            "provider" => "attempted-overwrite",
            "request_format" => "raw",
            "auth_kind" => "oauth2",
            "client_id" => ""
          }
        })

      assert has_element?(view, "#edit-connect-credential-modal")
      refute html =~ "Credential updated."
    end

    test "close_connect_credential_modal hides modal and clears edited values", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert has_element?(view, "#edit-connect-credential-modal")

      html = render_click(view, "close_connect_credential_modal", %{})

      refute has_element?(view, "#edit-connect-credential-modal")
      refute html =~ "Credential updated."
    end

    test "close_connect_grants_modal resets grants state", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Grants — #{credential.name}"

      render_click(view, "close_connect_grants_modal", %{})

      html_after = render(view)
      refute html_after =~ "Grants — #{credential.name}"
    end

    test "restore_connect_credential_scopes_defaults resets scopes to defaults", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert has_element?(view, "#edit-connect-credential-modal")

      html =
        render_click(view, "restore_connect_credential_scopes_defaults", %{})

      assert html =~ "edit-connect-credential-modal"
    end

    test "save_connect_credential error path shows validation errors", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Credential #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "",
            "provider" => "attempted-overwrite",
            "request_format" => "raw",
            "auth_kind" => "oauth2",
            "client_id" => "",
            "client_secret" => ""
          }
        })

      assert has_element?(view, "#edit-connect-credential-modal")
      refute html =~ "Credential updated."
    end

    test "save_connect_credential with newline-separated scopes parses correctly", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scope Parse Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Scope Test Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid",
            "client_secret" => "",
            "scopes" => "scope.read,\nscope.write,\n,scope.admin\n\n\nscope.other"
          }
        })

      assert html =~ "Credential updated."

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.name == "Scope Test Updated"
      assert updated.scopes == ["scope.read", "scope.write", "scope.admin", "scope.other"]
    end

    test "open_connect_grants with credential having no grants shows empty state", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "No Grants Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Grants — #{credential.name}"
      refute html =~ "bg-red-500"
    end
  end

  describe "MCP admin — error handling" do
    setup do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      :ok
    end

    test "add_mcp_row handles all collection types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      # Switch to remote to see headers
      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Row Test",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:8000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      # Test add headers row
      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='headers']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][1][key]']")

      # Test add secret_headers row
      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='secret_headers']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[secret_headers_rows][1][key]']")

      # Switch to local to see args and environments
      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Row Test",
          "type" => "local",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "",
          "command" => "echo",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      # Test add args row
      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='args']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[args_rows][1][value]']")

      # Test add environments row
      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='environments']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[environments_rows][1][key]']")

      # Test add secret_environments row
      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='secret_environments']")
      |> render_click()

      assert has_element?(view, "input[name='mcp_endpoint[secret_environments_rows][1][key]']")
    end

    test "add_mcp_row defaults to headers for unknown collection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Unknown Collection",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:8000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      # Call event directly to test catch-all collection_to_key clause
      render_click(view, "add_mcp_row", %{"collection" => "unknown"})

      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][1][key]']")
    end

    test "edit modal handles invalid secret headers gracefully", %{conn: conn} do
      {:ok, endpoint} =
        MCP.create_mcp_endpoint(%{
          name: "Bad Secret #{:erlang.unique_integer([:positive])}",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://localhost:8000/mcp",
          secret_headers: %{"Authorization" => "not-encrypted-plaintext"},
          settings: %{key: "value"}
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='#{endpoint.id}']")
      |> render_click()

      # Should still render the edit modal without crashing
      assert has_element?(view, "input[name='mcp_endpoint[name]']")
    end

    test "save MCP endpoint with non-map rows params exercises fallback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Fallback Rows MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{},
            "secret_headers_rows" => %{},
            "args_rows" => %{},
            "environments_rows" => %{},
            "secret_environments_rows" => %{},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved"
    end

    test "remove all rows from a collection keeps at least blank row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      # Switch to remote to see headers
      render_change(view, "validate_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Remove All",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:8000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      view
      |> element("button[phx-click='add_mcp_row'][phx-value-collection='headers']")
      |> render_click()

      view
      |> element(
        "button[phx-click='remove_mcp_row'][phx-value-collection='headers'][phx-value-index='0']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='remove_mcp_row'][phx-value-collection='headers'][phx-value-index='0']"
      )
      |> render_click()

      # After removing all rows, there should still be a blank row
      assert has_element?(view, "input[name='mcp_endpoint[headers_rows][0][key]']")
    end
  end

  describe "global settings error handling" do
    test "save_global_base_url with empty string is accepted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_base_url", %{
          "global_base_url" => ""
        })

      assert html =~ "Global base URL saved."
    end
  end

  describe "AI credential edge cases" do
    test "validate_ai_credential from edit mode keeps provider endpoint unchanged", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Stable Provider Cred",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Stable Provider Cred",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "",
            "sovereign" => "false",
            "description" => "still stable"
          }
        })

      assert html =~ "ai-credential-form"
    end
  end

  describe "scope parsing edge cases" do
    test "scope list with duplicates is deduplicated", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scope Dedup Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Scope Dedup Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid",
            "client_secret" => "",
            "scopes" => "scope.read, scope.write, scope.read, scope.write"
          }
        })

      assert html =~ "Credential updated."

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.scopes == ["scope.read", "scope.write"]
    end

    test "scope list with empty string is normalized", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scope Empty Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Scope Empty Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid",
            "client_secret" => "",
            "scopes" => ""
          }
        })

      assert html =~ "Credential updated."

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.scopes == []
    end

    test "scope list with only whitespace is normalized", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scope Whitespace Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Scope Whitespace Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid",
            "client_secret" => "",
            "scopes" => "   "
          }
        })

      assert html =~ "Credential updated."

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.scopes == []
    end
  end

  describe "LLM validate_llm — fusion weight edge cases" do
    test "validate_llm handles float fusion weights", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.8"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles out-of-range bm25 weight clamping", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.7"
          }
        })

      assert html =~ "llm-config-form"
    end
  end

  describe "MCP — save error handling" do
    setup do
      prev = Application.get_env(:zaq, :mcp_test_module)
      Application.put_env(:zaq, :mcp_test_module, MCPTestStub)

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:zaq, :mcp_test_module)
        else
          Application.put_env(:zaq, :mcp_test_module, prev)
        end
      end)

      :ok
    end

    test "save MCP endpoint with validation error preserves rows state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      render_submit(view, "save_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "0",
          "url" => "",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "val"}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => "test-arg"}},
          "environments_rows" => %{"0" => %{"key" => "ENV_VAR", "value" => "env_val"}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      # Modal is still open because validation failed
      assert has_element?(view, "#mcp-endpoint-modal")
      # Row data was preserved — check the form is still open with header content
      assert render(view) =~ "X-Test"
    end
  end

  describe "connect grants — error handling" do
    test "delete_connect_grant handles grant not found", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Delete Error Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      # Delete grant with non-existent ID
      html = render_click(view, "delete_connect_grant", %{"id" => "99999999"})
      assert html =~ "Grant not found."
    end

    test "trigger_connect_grant_refresh handles grant not found", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Refresh Error Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      # Trigger refresh with non-existent grant ID
      html = render_click(view, "trigger_connect_grant_refresh", %{"id" => "99999999"})
      assert html =~ "Grant not found."
    end

    test "close_connect_grants_modal clears grants and schedule", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Close Grants Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert render(view) =~ "Grants — #{credential.name}"

      render_click(view, "close_connect_grants_modal", %{})

      refute render(view) =~ "Grants — #{credential.name}"
    end

    test "save_connect_credential with non-map params is sanitized", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Sanitize Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret",
          scopes: ["original.scope"]
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_connect_credential", %{
          "credential" => %{
            "name" => "Sanitized Updated",
            "provider" => "google_drive",
            "request_format" => "bearer",
            "auth_kind" => "oauth2",
            "client_id" => "cid-updated",
            "client_secret" => "",
            "scopes" => ""
          }
        })

      assert html =~ "Credential updated."

      updated = Repo.get!(Zaq.Engine.Connect.Credential, credential.id)
      assert updated.name == "Sanitized Updated"
    end
  end

  describe "connect grants modal with mocked router" do
    setup [:with_node_router_mock_setup]

    test "delete and refresh grant error branches keep the modal open", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Mocked Grant Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "123",
          owner_type: "org",
          owner_id: 1,
          request_format: "bearer",
          status: "active",
          access_token: "access-live",
          refresh_token: "refresh-live",
          scopes: ["scope.read"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      error_changeset =
        Ecto.Changeset.add_error(
          Ecto.Changeset.change(%Zaq.Engine.Connect.Grant{}),
          :base,
          "boom"
        )

      stub_fn = fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_connect_list_credentials ->
            %Zaq.Event{event | response: [credential]}

          :system_config_connect_list_grants ->
            %Zaq.Event{event | response: [grant]}

          :system_config_connect_next_refresh_jobs_for_grants ->
            %Zaq.Event{event | response: %{grant.id => DateTime.utc_now()}}

          :system_config_connect_delete_grant ->
            %Zaq.Event{event | response: {:error, error_changeset}}

          :system_config_connect_schedule_refresh ->
            %Zaq.Event{event | response: {:error, error_changeset}}

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='open_connect_grants'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        view
        |> element(
          "button[phx-click='trigger_connect_grant_refresh'][phx-value-id='#{grant.id}']"
        )
        |> render_click()

      assert html =~ "Unable to queue grant refresh."
      assert render(view) =~ "#{grant.resource_type}:#{grant.resource_id}"

      html =
        view
        |> element("button[phx-click='delete_connect_grant'][phx-value-id='#{grant.id}']")
        |> render_click()

      assert html =~ "Unable to erase grant."
      assert render(view) =~ "#{grant.resource_type}:#{grant.resource_id}"
    end

    test "open_connect_grants with unknown id resets the grants modal state", %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Mocked Empty Grants Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      stub_fn = fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_connect_list_credentials ->
            %Zaq.Event{event | response: [credential]}

          :system_config_connect_list_grants ->
            %Zaq.Event{event | response: []}

          :system_config_connect_next_refresh_jobs_for_grants ->
            %Zaq.Event{event | response: %{}}

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      html = render_click(view, "open_connect_grants", %{"id" => "99999999"})

      assert html =~ "Grants"
      assert html =~ "No grants for this credential."
      refute html =~ "Grants — #{credential.name}"
    end

    test "restore_connect_credential_scopes_defaults dedupes and tolerates nil and invalid defaults",
         %{conn: conn} do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scopes Cred #{:erlang.unique_integer([:positive])}",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          client_id: "cid",
          client_secret: "csecret"
        })

      stub_fn = fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_connect_list_credentials ->
            %Zaq.Event{event | response: [credential]}

          :connect_fetch_credential ->
            %Zaq.Event{event | response: {:ok, credential}}

          :system_config_connect_change_credential ->
            scopes = Map.get(event.request[:attrs] || %{}, "scopes", [])

            %Zaq.Event{
              event
              | response:
                  Ecto.Changeset.change(credential, %{
                    scopes: scopes
                  })
            }

          :data_source_oauth_default_scopes ->
            %Zaq.Event{event | response: {:ok, ["a", " a ", ""]}}

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=auth_credentials")

      view
      |> element("button[phx-click='edit_connect_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert render(view) =~ "a,  a"

      html = render_click(view, "restore_connect_credential_scopes_defaults", %{})
      assert html =~ "a"

      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns: Map.put(state.socket.assigns, :connect_default_scopes_text, nil)
            }
        }
      end)

      html = render_click(view, "restore_connect_credential_scopes_defaults", %{})
      assert html =~ "edit-connect-credential-modal"

      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns: Map.put(state.socket.assigns, :connect_default_scopes_text, 123)
            }
        }
      end)

      html = render_click(view, "restore_connect_credential_scopes_defaults", %{})
      assert html =~ "edit-connect-credential-modal"
    end
  end

  describe "MCP payload and warning edge cases" do
    setup [:with_node_router_mock_setup]

    test "edit_mcp_endpoint tolerates malformed row params and non-binary secrets", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_mcp_filter_endpoints ->
            %Zaq.Event{
              event
              | response:
                  {[
                     %{
                       id: 999,
                       persisted?: true,
                       predefined?: false,
                       predefined_id: nil,
                       editable: true,
                       icon: nil,
                       description: nil,
                       auto_enabled: false,
                       name: "Mocked MCP",
                       type: "remote",
                       status: "enabled",
                       timeout_ms: 5000,
                       command: nil,
                       args: ["arg-1"],
                       url: "http://mock.dev",
                       headers: %{"X-Test" => "1"},
                       secret_headers: %{"Authorization" => 123},
                       environments: %{"ENV" => "1"},
                       secret_environments: %{"SECRET" => 456},
                       settings: %{}
                     }
                   ], 1}
            }

          :system_config_mcp_get_endpoint ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     id: 999,
                     name: "Mocked MCP",
                     type: "remote",
                     status: "enabled",
                     timeout_ms: 5000,
                     command: nil,
                     predefined_id: nil,
                     args: ["arg-1"],
                     headers: %{"X-Test" => "1"},
                     secret_headers: %{"Authorization" => 123},
                     environments: %{"ENV" => "1"},
                     secret_environments: %{"SECRET" => 456},
                     settings: %{}
                   }}
            }

          :system_config_mcp_change_endpoint ->
            %Zaq.Event{event | response: Ecto.Changeset.change(%Zaq.Agent.MCP.Endpoint{})}

          :mcp_endpoint_updated ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     endpoint: %{
                       id: 999,
                       name: "Mocked MCP",
                       persisted?: true,
                       predefined?: false,
                       predefined_id: nil,
                       editable: true,
                       icon: nil,
                       description: nil,
                       auto_enabled: false,
                       type: "remote",
                       status: "enabled",
                       timeout_ms: 5000,
                       command: nil,
                       args: [],
                       url: "http://mock.dev",
                       headers: %{},
                       secret_headers: %{},
                       environments: %{},
                       secret_environments: %{},
                       settings: %{}
                     },
                     runtime: %{}
                   }}
            }

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      html =
        render_change(view, "validate_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Mocked MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => 456,
            "command" => 123,
            "predefined_id" => 789,
            "headers_rows" => "bad",
            "secret_headers_rows" => "bad",
            "args_rows" => "bad",
            "environments_rows" => "bad",
            "secret_environments_rows" => "bad",
            "settings_text" => %{}
          }
        })

      assert html =~ "MCP Administration"

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Mocked MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => 456,
            "command" => 123,
            "predefined_id" => 789,
            "headers_rows" => "bad",
            "secret_headers_rows" => "bad",
            "args_rows" => "bad",
            "environments_rows" => "bad",
            "secret_environments_rows" => "bad",
            "settings_text" => %{}
          }
        })

      assert html =~ "MCP endpoint saved (Mocked MCP)."
    end

    test "save MCP endpoint shows and hides runtime warning flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        case {event.opts[:action], event.request[:action]} do
          {:system_config_mcp_filter_endpoints, _} ->
            %Zaq.Event{event | response: {stub_mcp_entries(), 1}}

          {:system_config_mcp_change_endpoint, _} ->
            %Zaq.Event{event | response: Ecto.Changeset.change(%Zaq.Agent.MCP.Endpoint{})}

          {:mcp_endpoint_updated, :update} ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     endpoint: %{
                       id: 999,
                       name: "Warnings MCP",
                       persisted?: true,
                       predefined?: false,
                       predefined_id: nil,
                       editable: true,
                       icon: nil,
                       description: nil,
                       auto_enabled: false,
                       type: "remote",
                       status: "enabled",
                       timeout_ms: 5000,
                       command: nil,
                       args: [],
                       url: "http://mock.dev",
                       headers: %{},
                       secret_headers: %{},
                       environments: %{},
                       secret_environments: %{},
                       settings: %{}
                     },
                     runtime: %{warnings: [:w1]}
                   }}
            }

          {:system_config_mcp_get_endpoint, _} ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     id: 999,
                     name: "Warnings MCP",
                     type: "remote",
                     status: "enabled",
                     timeout_ms: 5000,
                     command: nil,
                     predefined_id: nil,
                     args: [],
                     headers: %{},
                     secret_headers: %{},
                     environments: %{},
                     secret_environments: %{},
                     settings: %{}
                   }}
            }

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Warnings MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://mock.dev",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "MCP endpoint saved (Warnings MCP)."
    end

    test "save MCP endpoint with ok payload does not show runtime warnings", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        case {event.opts[:action], event.request[:action]} do
          {:system_config_mcp_filter_endpoints, _} ->
            %Zaq.Event{event | response: {stub_mcp_entries(), 1}}

          {:system_config_mcp_change_endpoint, _} ->
            %Zaq.Event{event | response: Ecto.Changeset.change(%Zaq.Agent.MCP.Endpoint{})}

          {:mcp_endpoint_updated, :update} ->
            %Zaq.Event{
              event
              | response: {:ok, %{endpoint: %{id: 999, name: "Silent MCP"}, runtime: :ok}}
            }

          {:system_config_mcp_get_endpoint, _} ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     id: 999,
                     name: "Silent MCP",
                     type: "remote",
                     status: "enabled",
                     timeout_ms: 5000,
                     command: nil,
                     predefined_id: nil,
                     args: [],
                     headers: %{},
                     secret_headers: %{},
                     environments: %{},
                     secret_environments: %{},
                     settings: %{}
                   }}
            }

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Silent MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://mock.dev",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      refute html =~ "MCP runtime warnings"
    end

    test "save MCP endpoint with non-map payload does not show runtime warnings", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        case {event.opts[:action], event.request[:action]} do
          {:system_config_mcp_filter_endpoints, _} ->
            %Zaq.Event{event | response: {stub_mcp_entries(), 1}}

          {:system_config_mcp_change_endpoint, _} ->
            %Zaq.Event{event | response: Ecto.Changeset.change(%Zaq.Agent.MCP.Endpoint{})}

          {:mcp_endpoint_updated, :update} ->
            %Zaq.Event{event | response: {:ok, :ok}}

          {:system_config_mcp_get_endpoint, _} ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     id: 999,
                     name: "Silent MCP",
                     type: "remote",
                     status: "enabled",
                     timeout_ms: 5000,
                     command: nil,
                     predefined_id: nil,
                     args: [],
                     headers: %{},
                     secret_headers: %{},
                     environments: %{},
                     secret_environments: %{},
                     settings: %{}
                   }}
            }

          _ ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Silent MCP",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://mock.dev",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      refute html =~ "MCP runtime warnings"
    end
  end

  # ── NodeRouter mock helpers ─────────────────────────────────────────────

  defp stub_mcp_entries do
    [
      %{
        id: 999,
        persisted?: true,
        predefined?: false,
        predefined_id: nil,
        editable: true,
        icon: nil,
        description: nil,
        auto_enabled: false,
        name: "Mock MCP Entry",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        command: nil,
        args: [],
        url: "http://mock.dev",
        headers: %{},
        secret_headers: %{},
        environments: %{},
        secret_environments: %{},
        settings: %{},
        endpoint: %Zaq.Agent.MCP.Endpoint{
          id: 999,
          name: "Mock MCP Entry",
          type: "remote",
          status: "enabled",
          timeout_ms: 5000,
          url: "http://mock.dev",
          command: nil,
          predefined_id: nil,
          args: [],
          headers: %{},
          secret_headers: %{},
          environments: %{},
          secret_environments: %{},
          settings: %{}
        }
      }
    ]
  end

  defp build_stub_response(%Zaq.Event{} = event) do
    action = event.opts[:action]
    response = stub_response_for_action(action)

    %Zaq.Event{event | response: response}
  end

  defp stub_response_for_action(:system_config_list_ai_provider_credentials), do: []
  defp stub_response_for_action(:system_config_connect_list_credentials), do: []
  defp stub_response_for_action(:system_config_agent_list_active_agents), do: []
  defp stub_response_for_action(:system_config_mcp_filter_endpoints), do: {stub_mcp_entries(), 1}
  defp stub_response_for_action(:system_config_mcp_predefined_catalog), do: %{}

  defp stub_response_for_action(:system_config_get_telemetry_config),
    do: %Zaq.System.TelemetryConfig{}

  defp stub_response_for_action(:system_config_get_llm_config), do: %Zaq.System.LLMConfig{}

  defp stub_response_for_action(:system_config_get_embedding_config),
    do: %Zaq.System.EmbeddingConfig{}

  defp stub_response_for_action(:system_config_get_image_to_text_config),
    do: %Zaq.System.ImageToTextConfig{}

  defp stub_response_for_action(:system_config_embedding_ready), do: false
  defp stub_response_for_action(:system_config_get_global_default_agent_id), do: nil
  defp stub_response_for_action(:system_config_get_global_base_url), do: nil

  defp stub_response_for_action(:system_config_change_ai_provider_credential) do
    Ecto.Changeset.cast(
      %Zaq.System.AIProviderCredential{},
      %{},
      ~w(name provider endpoint api_key sovereign description)a
    )
  end

  defp stub_response_for_action(:system_config_mcp_change_endpoint) do
    Ecto.Changeset.cast(
      %Zaq.Agent.MCP.Endpoint{},
      %{},
      ~w(name type status timeout_ms command args url headers secret_headers
         environments secret_environments settings predefined_id)a
    )
  end

  defp stub_response_for_action(:system_config_mcp_get_endpoint) do
    {:ok,
     %Zaq.Agent.MCP.Endpoint{
       id: 999,
       name: "Mock MCP Entry",
       type: "remote",
       status: "enabled",
       timeout_ms: 5000,
       url: "http://mock.dev",
       command: nil,
       predefined_id: nil,
       args: [],
       headers: %{},
       secret_headers: %{},
       environments: %{},
       secret_environments: %{},
       settings: %{}
     }}
  end

  defp stub_response_for_action(_), do: nil

  # Later: These error-branch tests now use the LiveView session seam instead of
  # global Application env. If they become flaky again, migrate them to narrower
  # gateway-level tests so each scenario owns its dependency process explicitly.
  defp with_node_router_mock_setup(%{conn: conn}) do
    %{conn: put_session(conn, :system_config_node_router_module, Zaq.NodeRouterMock)}
  end

  # ── Global settings error branches ─────────────────────────────────────

  describe "global settings error handling with mock" do
    setup [:with_node_router_mock_setup]

    test "save_global_default_agent error shows failure flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :system_config_set_global_default_agent_id do
          %Zaq.Event{event | response: {:error, :boom}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_default_agent", %{
          "global_default_agent_id" => "1"
        })

      assert html =~ "Failed to save global default agent"
    end

    test "save_global_base_url error shows failure flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :system_config_set_global_base_url do
          %Zaq.Event{event | response: {:error, :boom}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

      html =
        render_submit(view, "save_global_base_url", %{
          "global_base_url" => "https://fail.example"
        })

      assert html =~ "Failed to save global base URL"
    end
  end

  # ── MCP error branches (direct dispatch calls) ─────────────────────────

  describe "confirm_delete_mcp_endpoint error branches" do
    setup [:with_node_router_mock_setup]

    test "changeset error path shows form validation", %{conn: conn} do
      error_cs =
        Ecto.Changeset.add_error(
          Ecto.Changeset.cast(%Zaq.Agent.MCP.Endpoint{}, %{}, ~w(name)a),
          :name,
          "can't be blank"
        )

      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated and
             event.request[:action] == :delete do
          %Zaq.Event{event | response: {:error, error_cs}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      # Trigger edit to set mcp_endpoint_id
      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      render_click(view, "open_delete_mcp_endpoint_confirm", %{})
      html = render_click(view, "confirm_delete_mcp_endpoint", %{})

      assert html =~ "mcp-endpoint-modal"
    end

    test "reason error path shows error flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated and
             event.request[:action] == :delete do
          %Zaq.Event{event | response: {:error, :test_reason}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      render_click(view, "open_delete_mcp_endpoint_confirm", %{})
      html = render_click(view, "confirm_delete_mcp_endpoint", %{})

      assert html =~ "Failed to delete MCP endpoint"
      assert html =~ "test_reason"
    end

    test "unexpected response path shows fallback flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated and
             event.request[:action] == :delete do
          %Zaq.Event{event | response: :weird}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='edit_mcp_endpoint'][phx-value-id='999']")
      |> render_click()

      render_click(view, "open_delete_mcp_endpoint_confirm", %{})
      html = render_click(view, "confirm_delete_mcp_endpoint", %{})

      assert html =~ "Failed to delete MCP endpoint"
      assert html =~ ":weird"
    end
  end

  describe "enable_predefined_mcp error branches" do
    setup [:with_node_router_mock_setup]

    test "non-editable predefined endpoint does not open edit modal", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        cond do
          event.opts[:action] == :mcp_endpoint_updated ->
            %Zaq.Event{
              event
              | response:
                  {:ok,
                   %{
                     endpoint: %{
                       predefined_id: "non_editable_mcp",
                       name: "NonEditable"
                     },
                     runtime: %{}
                   }}
            }

          event.opts[:action] == :system_config_mcp_predefined_catalog ->
            %Zaq.Event{
              event
              | response: %{
                  "non_editable_mcp" => %{editable: false}
                }
            }

          true ->
            build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "enable_predefined_mcp", %{"predefined_id" => "non_editable_mcp"})

      assert html =~ "Predefined MCP enabled."
      refute has_element?(view, "#mcp-endpoint-modal")
    end

    test "error reason shows failure flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated do
          %Zaq.Event{event | response: {:error, :enable_failed}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "enable_predefined_mcp", %{"predefined_id" => "whatever"})

      assert html =~ "Failed to enable MCP"
      assert html =~ "enable_failed"
    end

    test "unexpected response shows fallback flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated do
          %Zaq.Event{event | response: :weird}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      html = render_click(view, "enable_predefined_mcp", %{"predefined_id" => "whatever"})

      assert html =~ "Failed to enable MCP"
      assert html =~ ":weird"
    end
  end

  describe "save_mcp_endpoint error branches" do
    setup [:with_node_router_mock_setup]

    test "changeset error path preserves modal and rows", %{conn: conn} do
      error_cs =
        Ecto.Changeset.add_error(
          Ecto.Changeset.cast(%Zaq.Agent.MCP.Endpoint{}, %{}, ~w(name)a),
          :name,
          "can't be blank"
        )

      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated do
          %Zaq.Event{event | response: {:error, error_cs}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      render_submit(view, "save_mcp_endpoint", %{
        "mcp_endpoint" => %{
          "name" => "Error Test",
          "type" => "remote",
          "status" => "enabled",
          "timeout_ms" => "5000",
          "url" => "http://localhost:8000/mcp",
          "command" => "",
          "predefined_id" => "",
          "headers_rows" => %{"0" => %{"key" => "X-Test", "value" => "val"}},
          "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "args_rows" => %{"0" => %{"value" => ""}},
          "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
          "settings_text" => "{}"
        }
      })

      assert has_element?(view, "#mcp-endpoint-modal")
    end

    test "reason error path shows error flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated do
          %Zaq.Event{event | response: {:error, :save_failed}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Reason Error",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "Failed to save MCP endpoint"
      assert html =~ "save_failed"
    end

    test "unexpected response shows fallback flash", %{conn: conn} do
      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :mcp_endpoint_updated do
          %Zaq.Event{event | response: :weird}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      view
      |> element("button[phx-click='new_mcp_endpoint']")
      |> render_click()

      html =
        render_submit(view, "save_mcp_endpoint", %{
          "mcp_endpoint" => %{
            "name" => "Weird Response",
            "type" => "remote",
            "status" => "enabled",
            "timeout_ms" => "5000",
            "url" => "http://localhost:8000/mcp",
            "command" => "",
            "predefined_id" => "",
            "headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_headers_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "args_rows" => %{"0" => %{"value" => ""}},
            "environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "secret_environments_rows" => %{"0" => %{"key" => "", "value" => ""}},
            "settings_text" => "{}"
          }
        })

      assert html =~ "Failed to save MCP endpoint"
      assert html =~ ":weird"
    end
  end

  # ── Provider pagination success path ────────────────────────────────────

  describe "MCP provider pagination success" do
    setup [:with_node_router_mock_setup]

    test "change MCP page with multiple pages renders paginated results", %{conn: conn} do
      entry_template = %{
        persisted?: true,
        predefined?: false,
        predefined_id: nil,
        editable: true,
        icon: nil,
        description: nil,
        auto_enabled: false,
        timeout_ms: 5000,
        command: nil,
        args: [],
        url: "http://mock.dev",
        headers: %{},
        secret_headers: %{},
        environments: %{},
        secret_environments: %{},
        settings: %{}
      }

      entries =
        Enum.map(1..25, fn i ->
          Map.merge(entry_template, %{
            id: i,
            name: "Paginated Endpoint #{i}",
            type: "remote",
            status: "disabled"
          })
        end)

      stub_fn = fn %Zaq.Event{} = event ->
        if event.opts[:action] == :system_config_mcp_filter_endpoints do
          page = event.request[:page] || event.request["page"] || 1
          per_page = event.request[:per_page] || event.request["per_page"] || 20

          page_entries =
            entries
            |> Enum.drop((page - 1) * per_page)
            |> Enum.take(per_page)

          %Zaq.Event{event | response: {page_entries, 25}}
        else
          build_stub_response(event)
        end
      end

      Mox.stub(Zaq.NodeRouterMock, :dispatch, stub_fn)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=mcps")

      assert render(view) =~ "Paginated Endpoint 1"
      assert render(view) =~ "Paginated Endpoint 20"
      refute render(view) =~ "Paginated Endpoint 21"

      html = render_click(view, "change_mcp_page", %{"page" => "2"})

      assert html =~ "Paginated Endpoint 21"
      assert html =~ "Paginated Endpoint 25"
      refute html =~ "Paginated Endpoint 1"
    end
  end

  defp unsupported_llmdb_provider_option do
    LLMDB.providers()
    |> Enum.reject(fn provider ->
      provider.alias_of || provider.catalog_only || match?({:ok, _}, ReqLLM.provider(provider.id))
    end)
    |> Enum.find(fn provider ->
      provider.id
      |> LLMDB.models()
      |> Enum.any?(fn model -> not model.deprecated and not model.retired end)
    end)
    |> case do
      nil ->
        nil

      provider ->
        {provider.name || humanize_provider_id(provider.id), Atom.to_string(provider.id)}
    end
  rescue
    _ -> nil
  end

  defp humanize_provider_id(provider_id) do
    provider_id
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp restore_show_unsupported_ai_providers(nil),
    do: Application.delete_env(:zaq, :show_unsupported_ai_providers)

  defp restore_show_unsupported_ai_providers(value),
    do: Application.put_env(:zaq, :show_unsupported_ai_providers, value)
end
