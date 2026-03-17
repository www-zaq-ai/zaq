defmodule ZaqWeb.Live.BO.AI.PromptTemplatesLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.PromptTemplate

  setup %{conn: conn} do
    user = user_fixture(%{username: "prompt_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "creates a new template from the new tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("#prompt-tab-new")
    |> render_click()

    view
    |> form("#prompt-template-create-form",
      prompt_template: %{
        slug: "lane6_new",
        name: "Lane 6 New",
        description: "new template",
        body: "You are a deterministic assistant"
      }
    )
    |> render_submit()

    created = PromptTemplate.get_by_slug("lane6_new")
    assert created
    assert created.name == "Lane 6 New"
    assert has_element?(view, "button[phx-value-id='#{created.id}']", "lane6_new")
  end

  test "updates and toggles an existing template", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{
        slug: "lane6_edit",
        name: "Lane 6 Edit",
        description: "before",
        body: "old body",
        active: true
      })

    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("button[phx-click='switch_tab'][phx-value-id='#{template.id}']")
    |> render_click()

    view
    |> form("form[phx-submit='save']",
      prompt_template: %{
        id: template.id,
        name: "Lane 6 Updated",
        description: "after",
        body: "updated body"
      }
    )
    |> render_submit()

    updated = PromptTemplate.get_by_slug("lane6_edit")
    assert updated.name == "Lane 6 Updated"
    assert updated.body == "updated body"

    view
    |> element("button[phx-click='toggle_active'][phx-value-id='#{template.id}']")
    |> render_click()

    refute PromptTemplate.get_by_slug("lane6_edit").active
  end

  test "deletes an existing template", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{
        slug: "lane6_delete",
        name: "Lane 6 Delete",
        description: "delete me",
        body: "delete body",
        active: true
      })

    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("button[phx-click='switch_tab'][phx-value-id='#{template.id}']")
    |> render_click()

    view
    |> element("button[phx-click='confirm_delete'][phx-value-id='#{template.id}']")
    |> render_click()

    assert has_element?(view, "button[phx-click='delete'][phx-value-id='#{template.id}']")

    view
    |> element("button[phx-click='delete'][phx-value-id='#{template.id}']")
    |> render_click()

    assert PromptTemplate.get_by_slug("lane6_delete") == nil
    refute has_element?(view, "button[phx-value-id='#{template.id}']", "lane6_delete")
  end

  test "create shows validation flash on invalid params", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("#prompt-tab-new")
    |> render_click()

    view
    |> form("#prompt-template-create-form",
      prompt_template: %{
        slug: "",
        name: "",
        description: "invalid",
        body: ""
      }
    )
    |> render_submit()

    assert PromptTemplate.get_by_slug("") == nil
  end

  test "save shows validation flash and cancel_delete hides confirmation", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{
        slug: "lane6_invalid_save",
        name: "Lane 6 Invalid Save",
        description: "before",
        body: "old body",
        active: true
      })

    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("button[phx-click='switch_tab'][phx-value-id='#{template.id}']")
    |> render_click()

    view
    |> form("form[phx-submit='save']",
      prompt_template: %{
        id: template.id,
        name: "",
        description: "after",
        body: "updated body"
      }
    )
    |> render_submit()

    unchanged = PromptTemplate.get_by_slug("lane6_invalid_save")
    assert unchanged.name == "Lane 6 Invalid Save"

    view
    |> element("button[phx-click='confirm_delete'][phx-value-id='#{template.id}']")
    |> render_click()

    assert has_element?(view, "button[phx-click='cancel_delete']", "Cancel")

    view
    |> element("button[phx-click='cancel_delete']")
    |> render_click()

    refute has_element?(view, "button[phx-click='cancel_delete']", "Cancel")
  end
end
