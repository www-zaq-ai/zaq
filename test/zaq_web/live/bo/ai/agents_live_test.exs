defmodule ZaqWeb.Live.BO.AI.AgentsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts

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

  test "shows file tools from registry in the form", %{conn: conn} do
    _credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    {:ok, view, _html} = live(conn, ~p"/bo/agents")

    render_click(element(view, "#new-agent-button"))

    html = render(view)
    assert html =~ "Read file"
    assert html =~ "Write file"
    assert html =~ "List directory"
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
        "enabled_tool_keys" => ["files.read_file"],
        "advanced_options_json" => "{}",
        "conversation_enabled" => "false",
        "active" => "true"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "Selected model does not support tool calling"
    assert html =~ "enabled_tool_keys: selected model does not support tool calling"
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

  test "cancel button closes form without persisting changes", %{conn: conn} do
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
        "conversation_enabled" => "true",
        "active" => "true"
      }
    )
    |> render_change()

    render_click(element(view, "#cancel-agent-button"))

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
        "conversation_enabled" => "true",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Agent created"
    assert render(view) =~ agent_name
    assert Enum.any?(Zaq.Agent.list_agents(), &(&1.name == agent_name))
  end
end
