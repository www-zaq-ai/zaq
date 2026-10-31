defmodule ZaqWeb.Live.BO.ModelOwnershipTest do
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures
  import Mox

  alias Zaq.{Accounts, Agent, System}

  setup %{conn: conn} do
    user = user_fixture(%{username: "model-ownership-admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> :services@localhost end)
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "translation and small-model forms save independent selections and clear model on credential change",
       %{conn: conn} do
    credential = ai_credential_fixture(%{provider: "openai"})
    other = ai_credential_fixture(%{provider: "openai", name: "Other text model credential"})
    {:ok, view, _} = live(conn, ~p"/bo/system-config?tab=rag")
    assert has_element?(view, "#retrieval-section #translation-model-form")
    assert has_element?(view, "#retrieval-section #rag-retrieval-advanced:not([open])")
    refute has_element?(view, "#embedding-section #retrieval-config-form")

    render_submit(view, "save_operation_model", %{
      "kind" => "translation",
      "operation_model_config" => %{
        "credential_id" => to_string(credential.id),
        "model" => "gpt-4o"
      }
    })

    assert System.get_operation_model_config(:translation).model == "gpt-4o"
    assert System.get_operation_model_config(:small).model == nil

    render_change(view, "validate_operation_model", %{
      "kind" => "translation",
      "operation_model_config" => %{"credential_id" => to_string(other.id), "model" => "gpt-4o"}
    })

    assert has_element?(view, "#translation-model-select input[value='']")
    assert System.get_operation_model_config(:translation).credential_id == credential.id

    {:ok, global, _} = live(conn, ~p"/bo/system-config?tab=global")

    render_submit(global, "save_operation_model", %{
      "kind" => "small",
      "operation_model_config" => %{
        "credential_id" => to_string(other.id),
        "model" => "gpt-4o-mini"
      }
    })

    assert System.get_operation_model_config(:small).model == "gpt-4o-mini"
    assert System.get_operation_model_config(:translation).model == "gpt-4o"
  end

  test "agent identity sits above collapsed advanced controls with explicit sampling defaults and error expansion",
       %{conn: conn} do
    credential = ai_credential_fixture(%{provider: "openai"})
    {:ok, view, _} = live(conn, ~p"/bo/agents")
    render_click(element(view, "#new-agent-button"))
    assert has_element?(view, "#agent-identity-settings input[name='configured_agent[name]']")
    assert has_element?(view, "#agent-identity-settings button[phx-value-field='active']")

    assert has_element?(
             view,
             "#agent-identity-settings button[phx-value-field='conversation_enabled']"
           )

    assert has_element?(view, "#agent-advanced-options:not([open])")

    assert has_element?(
             view,
             "#agent-advanced-options input[name='configured_agent[temperature]'][value='0.0']"
           )

    assert has_element?(
             view,
             "#agent-advanced-options input[name='configured_agent[top_p]'][value='0.9']"
           )

    assert has_element?(
             view,
             "#agent-advanced-options textarea[name='configured_agent[advanced_options_json]']"
           )

    attrs = %{
      name: "Sampling Agent",
      job: "Help",
      credential_id: credential.id,
      model: "gpt-4o",
      temperature: "0.25",
      top_p: "0.8",
      advanced_options_json: ~s({"temperature":1.9,"max_tokens":128})
    }

    view
    |> form("#configured-agent-form", %{configured_agent: Map.put(attrs, :top_p, "0")})
    |> render_submit()

    assert has_element?(view, "#agent-advanced-options[open]")

    view |> form("#configured-agent-form", %{configured_agent: attrs}) |> render_submit()
    agent = Enum.find(Agent.list_agents(), &(&1.name == "Sampling Agent"))
    assert agent.temperature == 0.25
    assert agent.top_p == 0.8
    assert agent.advanced_options["max_tokens"] == 128
  end
end
