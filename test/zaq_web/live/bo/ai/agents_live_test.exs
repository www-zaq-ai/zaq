defmodule ZaqWeb.Live.BO.AI.AgentsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Ecto.Changeset
  alias Zaq.Accounts
  alias Zaq.Agent.MCP
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem
  alias ZaqWeb.Live.BO.AI.AgentsLive

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "agents-admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "renders agents page", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, html} = live(conn, ~p"/bo/agents")

    assert html =~ "AI Agents"
    assert has_element?(view, "#new-agent-button")
    refute has_element?(view, "#configured-agent-form")
    refute has_element?(view, "#agents-detail-pane")

    {ai_pos, _} = :binary.match(html, "section-ai")
    {data_pos, _} = :binary.match(html, "section-data")
    assert ai_pos < data_pos
  end

  test "shows form only after clicking new agent", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    refute has_element?(view, "#configured-agent-form")

    render_click(element(view, "#new-agent-button"))

    assert has_element?(view, "#configured-agent-form")
    assert has_element?(view, "#agents-detail-pane")
    assert render(view) =~ "Create Agent"
  end

  test "shows unselected tools in searchable add-tools modal", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))
    render_click(element(view, "#add-tools-button"))

    html = render(view)
    assert html =~ "Add tools"
    assert html =~ "Read file"
    assert html =~ "Write file"
    assert html =~ "List directory"
  end

  test "renders MCP section above tools and supports add/remove", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, enabled_endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Enabled MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, _disabled_endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Disabled MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "disabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    html = render(view)
    {mcp_pos, _} = :binary.match(html, "MCP Endpoints")
    {tools_pos, _} = :binary.match(html, "Enabled Tools")
    assert mcp_pos < tools_pos

    render_click(element(view, "#add-mcp-button"))

    modal_html = render(view)
    assert modal_html =~ "Enabled MCP"
    refute modal_html =~ "Disabled MCP"

    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => to_string(enabled_endpoint.id)})

    assert has_element?(view, ~s([data-selected-mcp-endpoint-id="#{enabled_endpoint.id}"]))

    view
    |> element(
      "#configured-agent-form button[phx-click='remove_mcp'][phx-value-id='#{enabled_endpoint.id}']"
    )
    |> render_click()

    refute has_element?(view, ~s([data-selected-mcp-endpoint-id="#{enabled_endpoint.id}"]))
  end

  test "list hides delete button and shows status dot in name", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, active_agent} =
      Zaq.Agent.create_agent(%{
        name: "Active Dot Agent #{:erlang.unique_integer([:positive])}",
        description: "",
        job: "test",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    {:ok, inactive_agent} =
      Zaq.Agent.create_agent(%{
        name: "Inactive Dot Agent #{:erlang.unique_integer([:positive])}",
        description: "",
        job: "test",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: false,
        advanced_options: %{}
      })

    {:ok, view, html} = live(conn, ~p"/bo/agents")

    refute html =~ "Delete"
    assert has_element?(view, "#agent-row-#{active_agent.id} span.bg-emerald-500")
    assert has_element?(view, "#agent-row-#{inactive_agent.id} span.bg-red-500")
    assert html =~ "Conversation"
  end

  test "shows unsupported-tools indication when selected model has no tool support", %{conn: conn} do
    credential =
      ai_credential_fixture(%{
        name: "Unsupported Model Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "not-a-real-model",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "Selected model does not support tool calling"
  end

  test "clicking a row opens edit form", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Row Select Agent #{:erlang.unique_integer([:positive])}",
        description: "row",
        job: "You are row selected",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    assert has_element?(view, "#configured-agent-form")
    assert render(view) =~ "Edit Agent"
    assert render(view) =~ agent.name
  end

  test "edit form shows delete button", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Delete Button Agent #{:erlang.unique_integer([:positive])}",
        description: "delete",
        job: "Delete me",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    assert has_element?(view, "#delete-agent-button")
  end

  test "cannot delete agent when used in routing config and shows usage locations", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Delete Guard UI Agent #{:erlang.unique_integer([:positive])}",
        description: "delete",
        job: "Delete guarded",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "MM",
        kind: "retrieval",
        url: "https://mattermost.example.com",
        token: "tok",
        enabled: true,
        settings: %{}
      })

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "guard-chan",
      channel_name: "Guard",
      team_id: "team-1",
      team_name: "Team",
      active: true,
      configured_agent_id: agent.id
    })
    |> Repo.insert!()

    :ok = ZaqSystem.set_global_default_agent_id(agent.id)

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    view
    |> element("#delete-agent-button")
    |> render_click()

    assert render(view) =~ "retrieval channel"
    assert render(view) =~ "global default"
  end

  test "lists credential provider and sovereign status", %{conn: conn} do
    sovereign_credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        sovereign: true
      })

    {:ok, _agent} =
      Zaq.Agent.create_agent(%{
        name: "Provider Sovereign Agent #{:erlang.unique_integer([:positive])}",
        description: "",
        job: "Test",
        model: "gpt-4.1-mini",
        credential_id: sovereign_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, _view, html} = live(conn, ~p"/bo/agents")

    assert html =~ "openai"
    assert html =~ "Sovereign"
  end

  test "filters agents by sovereign status", %{conn: conn} do
    sovereign_credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        sovereign: true
      })

    standard_credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        sovereign: false
      })

    sovereign_name = "Sovereign Agent #{:erlang.unique_integer([:positive])}"
    standard_name = "Standard Agent #{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      Zaq.Agent.create_agent(%{
        name: sovereign_name,
        description: "",
        job: "Test",
        model: "gpt-4.1-mini",
        credential_id: sovereign_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, _} =
      Zaq.Agent.create_agent(%{
        name: standard_name,
        description: "",
        job: "Test",
        model: "gpt-4.1-mini",
        credential_id: standard_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> form("#agent-filters-form", %{
      "filters" => %{
        "name" => "",
        "model" => "",
        "conversation_enabled" => "all",
        "active" => "all",
        "sovereign" => "sovereign"
      }
    })
    |> render_change()

    html = render(view)
    assert html =~ sovereign_name
    refute html =~ standard_name
  end

  test "top-right close button closes form without persisting changes", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "Transient Agent",
        "description" => "",
        "job" => "",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "idle_time_seconds" => "900",
        "active" => "true"
      }
    )
    |> render_change()

    render_click(element(view, "#close-agent-detail"))

    refute has_element?(view, "#configured-agent-form")
    refute Enum.any?(Zaq.Agent.list_agents(), &(&1.name == "Transient Agent"))
  end

  test "uses searchable select for model when provider has model options", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_change()

    assert has_element?(view, "#configured-agent-model-select")
  end

  test "creates agent from form", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    agent_name = "BO Agent #{:erlang.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => agent_name,
        "description" => "Test description",
        "job" => "You are a helper",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "idle_time_seconds" => "900",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Agent created"
    assert render(view) =~ agent_name
    assert Enum.any?(Zaq.Agent.list_agents(), &(&1.name == agent_name))
  end

  test "does not show field validation errors on change before save", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{not-json",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_change()

    html = render(view)
    refute html =~ "advanced options must be valid JSON"
  end

  test "save with invalid advanced options json keeps form in validation state", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "Broken JSON Save",
        "description" => "",
        "job" => "You are a helper",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{broken",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "advanced options must be valid JSON"
    refute html =~ "Agent created"
  end

  test "does not show object-shape advanced options error on change before save", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "[1,2,3]",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_change()

    html = render(view)
    refute html =~ "advanced options must be a JSON object"
  end

  test "edits an existing agent", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    name = "Editable Agent #{System.unique_integer([:positive])}"

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: name,
        description: "before",
        job: "You are v1",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "#{name} Updated",
        "description" => "after",
        "job" => "You are v2",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Agent updated"
    assert render(view) =~ "#{name} Updated"
  end

  test "edit notice includes stopped runtime server count when update kills servers", %{
    conn: conn
  } do
    credential =
      ai_credential_fixture(%{
        name: "Notice Count Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    name = "Notice Count Agent #{System.unique_integer([:positive])}"

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: name,
        description: "before",
        job: "You are v1",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    server_id = "agent:mattermost:person:#{agent.id}"
    assert {:ok, _ref} = ServerManager.ensure_server(agent, server_id)

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => "#{name} Updated",
        "description" => "after",
        "job" => "You are v2",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "idle_time_seconds" => "900",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~
             "Agent updated. 1 runtime server stopped; it will restart on next message."

    assert render(view) =~ "#{name} Updated"
  end

  test "save fails for duplicate name on create and update", %{conn: conn} do
    credential =
      ai_credential_fixture(%{
        name: "Duplicate Name Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    existing_name = "Duplicate Agent #{System.unique_integer([:positive])}"

    {:ok, existing} =
      Zaq.Agent.create_agent(%{
        name: existing_name,
        description: "",
        job: "existing",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, to_update} =
      Zaq.Agent.create_agent(%{
        name: "Updatable Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "update",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => existing_name,
        "description" => "",
        "job" => "new",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "has already been taken"

    view
    |> element("#agent-row-#{to_update.id}")
    |> render_click()

    view
    |> form("#configured-agent-form",
      configured_agent: %{
        "name" => existing.name,
        "description" => "",
        "job" => "changed",
        "model" => "gpt-4.1-mini",
        "credential_id" => to_string(credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "has already been taken"
  end

  test "validation accepts empty advanced options and non-list tool keys", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    html =
      render_change(view, "validate", %{
        "configured_agent" => %{
          "name" => "Inline Tool Key",
          "description" => "",
          "job" => "Job",
          "model" => "gpt-4.1-mini",
          "credential_id" => to_string(credential.id),
          "strategy" => "react",
          "enabled_tool_keys" => "files.read_file",
          "advanced_options_json" => "",
          "conversation_enabled" => "false",
          "active" => "true"
        }
      })

    refute html =~ "advanced options must be valid JSON"
  end

  test "validation with invalid credential ids keeps model options empty", %{conn: conn} do
    ai_credential_fixture(%{
      provider: "provider_not_found_zaq",
      endpoint: "https://example.com/v1"
    })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "credential_id" => "abc",
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    refute has_element?(view, "#configured-agent-model-select")

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "credential_id" => "999999999",
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    refute has_element?(view, "#configured-agent-model-select")
  end

  test "validation keeps model options empty for missing and blank credential ids", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    refute has_element?(view, "#configured-agent-model-select")

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "credential_id" => "",
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    refute has_element?(view, "#configured-agent-model-select")
  end

  test "validation handles provider ids unknown to existing atoms", %{conn: conn} do
    unknown_provider_credential =
      ai_credential_fixture(%{
        provider: "provider_not_found_zaq",
        endpoint: "https://example.com/v1"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => "",
        "description" => "",
        "job" => "",
        "model" => "",
        "credential_id" => to_string(unknown_provider_credential.id),
        "strategy" => "react",
        "enabled_tool_keys" => [""],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    refute has_element?(view, "#configured-agent-model-select")
  end

  test "validation accepts unsupported tool-key shape as empty selection", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    html =
      render_change(view, "validate", %{
        "configured_agent" => %{
          "name" => "Tool Shape",
          "description" => "",
          "job" => "Job",
          "model" => "gpt-4.1-mini",
          "credential_id" => to_string(credential.id),
          "strategy" => "react",
          "enabled_tool_keys" => 123,
          "advanced_options_json" => "{}",
          "conversation_enabled" => "false",
          "active" => "true"
        }
      })

    assert html =~ "Tool Shape"
  end

  test "selecting an already-listed row does not re-query configured_agents", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "No Requery Row #{System.unique_integer([:positive])}",
        description: "",
        job: "row",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    attach_repo_query_telemetry(self())

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    _ = drain_repo_query_sources()

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    sources = drain_repo_query_sources()
    refute Enum.any?(sources, &(&1 == "configured_agents"))
  end

  test "edit-mode validate does not re-query credential or selected agent", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "No Requery Validate #{System.unique_integer([:positive])}",
        description: "existing",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    attach_repo_query_telemetry(self())

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    _ = drain_repo_query_sources()

    render_change(view, "validate", %{
      "configured_agent" => %{
        "name" => agent.name,
        "description" => "updated",
        "job" => agent.job,
        "model" => agent.model,
        "credential_id" => to_string(agent.credential_id),
        "strategy" => agent.strategy,
        "enabled_tool_keys" => [],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    })

    sources = drain_repo_query_sources()
    refute Enum.any?(sources, &(&1 == "ai_provider_credentials"))
    refute Enum.any?(sources, &(&1 == "configured_agents"))
  end

  test "validate handles non-binary advanced options payloads in raw event calls without surfacing error" do
    {:ok, socket} = AgentsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      AgentsLive.handle_event(
        "validate",
        %{
          "configured_agent" => %{
            "name" => "Raw Payload",
            "description" => "",
            "job" => "",
            "model" => "",
            "strategy" => "react",
            "enabled_tool_keys" => 123,
            "advanced_options_json" => %{},
            "conversation_enabled" => "false",
            "active" => "true"
          }
        },
        socket
      )

    assert socket.assigns.advanced_options_error == nil
    assert Changeset.get_field(socket.assigns.changeset, :enabled_tool_keys) == []
  end

  test "tools modal lists enabled tools and allows removing from modal", %{conn: conn} do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Modal Tool Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "tool modal",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["files.read_file"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    view
    |> element("#agent-row-#{agent.id}")
    |> render_click()

    render_click(element(view, "#add-tools-button"))

    html = render(view)
    assert html =~ "Enabled tools"
    assert html =~ "Read file"

    view
    |> element("#agent-tools-picker-modal button[phx-click=\"remove_tool\"]")
    |> render_click()

    refute has_element?(view, ~s([data-selected-tool-key="files.read_file"]))
  end

  test "picker open/close and empty add events are no-ops", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Picker MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    render_click(element(view, "#add-tools-button"))
    assert has_element?(view, "#agent-tools-picker-modal")

    render_click(
      element(view, "#agent-tools-picker-modal button[phx-click='close_tools_picker']")
    )

    refute has_element?(view, "#agent-tools-picker-modal")

    render_change(view, "add_tool_from_picker", %{"tool_key" => ""})
    refute has_element?(view, "[data-selected-tool-key]")

    render_click(element(view, "#add-mcp-button"))
    assert has_element?(view, "#agent-mcp-picker-modal")

    render_click(element(view, "#agent-mcp-picker-modal button[phx-click='close_mcp_picker']"))
    refute has_element?(view, "#agent-mcp-picker-modal")

    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => ""})
    refute has_element?(view, "[data-selected-mcp-endpoint-id]")

    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => to_string(endpoint.id)})
    assert has_element?(view, ~s([data-selected-mcp-endpoint-id="#{endpoint.id}"]))
  end

  test "toggle_form_boolean updates conversation and active values", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))

    before = render(view)

    render_click(
      element(
        view,
        "button[phx-click='toggle_form_boolean'][phx-value-field='conversation_enabled']"
      )
    )

    render_click(
      element(view, "button[phx-click='toggle_form_boolean'][phx-value-field='active']")
    )

    after_html = render(view)

    refute before == after_html
  end

  defp attach_repo_query_telemetry(test_pid) do
    ref = make_ref()
    handler_id = {__MODULE__, :repo_query, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:zaq, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:repo_query, metadata[:source]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp drain_repo_query_sources(acc \\ []) do
    receive do
      {:repo_query, source} -> drain_repo_query_sources([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
