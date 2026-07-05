defmodule ZaqWeb.Live.BO.AI.SkillsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.Skills

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "skills-admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  defp create_skill!(attrs) do
    {:ok, skill} =
      %{body: "Instructions.", tool_keys: [], tags: []}
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  test "renders skills page with empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/bo/skills")

    assert html =~ "Agent Skills"
    assert html =~ "No skills found."
    assert has_element?(view, "#new-skill-button")
    refute has_element?(view, "#skill-form")
  end

  test "lists existing skills with tags and status", %{conn: conn} do
    create_skill!(%{name: "listed-skill", tags: ["math"], description: "Does math"})
    create_skill!(%{name: "retired-skill", active: false})

    {:ok, _view, html} = live(conn, ~p"/bo/skills")

    assert html =~ "listed-skill"
    assert html =~ "Does math"
    assert html =~ "math"
    assert html =~ "retired-skill"
    assert html =~ "inactive"
  end

  test "filters skills by free text and tags", %{conn: conn} do
    create_skill!(%{name: "math-helper", tags: ["math"]})
    create_skill!(%{name: "web-search", tags: ["web"]})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    html =
      view
      |> form("#skills-filter-form", filters: %{"q" => "math", "tag" => ""})
      |> render_change()

    assert html =~ "math-helper"
    refute html =~ "web-search"

    html =
      view
      |> form("#skills-filter-form", filters: %{"q" => "", "tag" => "web"})
      |> render_change()

    assert html =~ "web-search"
    refute html =~ "math-helper"
  end

  test "creates a skill from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    assert has_element?(view, "#skill-form")

    view
    |> form("#skill-tool-picker", %{"tool_key" => "answering.search_knowledge_base"})
    |> render_change()

    view
    |> form("#skill-form",
      skill: %{
        "name" => "created-skill",
        "description" => "From the BO",
        "body" => "Do it well.",
        "tags" => "math, Utility",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill created"

    assert [skill] = Skills.search_skills(%{q: "created-skill"})
    assert skill.tool_keys == ["answering.search_knowledge_base"]
    assert skill.tags == ["math", "utility"]
  end

  test "shows validation errors on invalid create", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))

    html =
      view
      |> form("#skill-form", skill: %{"name" => "Bad Name", "body" => "b", "tags" => ""})
      |> render_submit()

    assert html =~ "must be lowercase kebab-case"
    assert Skills.list_skills() == []
  end

  test "edits an existing skill", %{conn: conn} do
    skill = create_skill!(%{name: "editable-skill", body: "Old."})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))
    assert has_element?(view, "#skill-form")
    assert render(view) =~ "Edit Skill"

    view
    |> form("#skill-form",
      skill: %{
        "name" => "editable-skill",
        "description" => "",
        "body" => "New body.",
        "tags" => "updated",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill saved"

    updated = Skills.get_skill!(skill.id)
    assert updated.body == "New body."
    assert updated.tags == ["updated"]
  end

  test "adds and removes tools via the picker", %{conn: conn} do
    skill = create_skill!(%{name: "toolable", tool_keys: ["answering.search_knowledge_base"]})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#skill-row-#{skill.id}"))

    assert render(view) =~ "Search knowledge base"

    view
    |> form("#skill-tool-picker", %{"tool_key" => "data_source.get_document"})
    |> render_change()

    view
    |> element("button[phx-click=remove_tool][phx-value-key='answering.search_knowledge_base']")
    |> render_click()

    view
    |> form("#skill-form",
      skill: %{
        "name" => "toolable",
        "description" => "",
        "body" => "Instructions.",
        "tags" => "",
        "active" => "true"
      }
    )
    |> render_submit()

    assert Skills.get_skill!(skill.id).tool_keys == ["data_source.get_document"]
  end

  test "deletes a skill", %{conn: conn} do
    skill = create_skill!(%{name: "deletable-skill"})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#delete-skill-#{skill.id}"))

    assert render(view) =~ "Skill deleted"
    assert Skills.get_skill(skill.id) == nil
  end

  test "cancel hides the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    assert has_element?(view, "#skill-form")

    render_click(element(view, "button[phx-click=cancel_form]"))
    refute has_element?(view, "#skill-form")
  end
end
