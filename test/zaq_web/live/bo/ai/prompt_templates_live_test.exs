defmodule ZaqWeb.Live.BO.AI.PromptTemplatesLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  require Ecto.Query

  alias Zaq.Accounts
  alias Zaq.Agent.PromptTemplate

  setup %{conn: conn} do
    user = user_fixture(%{username: "prompt_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "restore persists the latest default, discards body draft, and keeps metadata draft", %{
    conn: conn
  } do
    {:ok, template} =
      PromptTemplate.create(%{slug: "restore_test", name: "Saved name", body: "Baseline"})

    {:ok, template} = PromptTemplate.update(template, %{body: "Customized"})
    {:ok, view, _} = live(conn, ~p"/bo/prompt-templates")
    view |> element("#prompt-tab-restore_test") |> render_click()

    view
    |> form("#prompt-template-edit-form-#{template.id}",
      prompt_template: %{name: "Draft name", description: "Draft description", body: "Draft body"}
    )
    |> render_change()

    Zaq.Repo.update_all(
      Ecto.Query.from(t in PromptTemplate, where: t.id == ^template.id),
      set: [default_body: "Latest baseline"]
    )

    view |> element("#restore-template-#{template.id}") |> render_click()
    restored = PromptTemplate.get_by_slug(template.slug)
    assert restored.body == "Latest baseline"
    refute restored.body_customized
    assert restored.name == "Saved name"
    assert restored.description == nil
    assert has_element?(view, "input[name='prompt_template[name]'][value='Draft name']")
    assert has_element?(view, "textarea[name='prompt_template[body]']", "Latest baseline")
    refute render(view) =~ "Draft body"

    {:ok, reloaded, _} = live(conn, ~p"/bo/prompt-templates")
    reloaded |> element("#prompt-tab-restore_test") |> render_click()
    assert has_element?(reloaded, "textarea[name='prompt_template[body]']", "Latest baseline")
  end

  test "legacy templates without defaults cannot restore, including forged clicks", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{slug: "legacy_restore", name: "Legacy", body: "Keep"})

    Zaq.Repo.update_all(
      Ecto.Query.from(t in PromptTemplate, where: t.id == ^template.id),
      set: [default_body: nil, body_customized: true]
    )

    {:ok, view, _} = live(conn, ~p"/bo/prompt-templates")
    view |> element("#prompt-tab-legacy_restore") |> render_click()
    assert has_element?(view, "#restore-template-#{template.id}[disabled]")
    render_click(view, "restore_default", %{"id" => to_string(template.id)})
    assert PromptTemplate.get_by_slug(template.slug).body == "Keep"
    assert render(view) =~ "No default is available"
  end

  test "deleted templates fail restore without losing unsaved content", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{slug: "deleted_restore", name: "Deleted", body: "Baseline"})

    {:ok, view, _} = live(conn, ~p"/bo/prompt-templates")
    view |> element("#prompt-tab-deleted_restore") |> render_click()

    view
    |> form("#prompt-template-edit-form-#{template.id}", prompt_template: %{body: "Keep draft"})
    |> render_change()

    Zaq.Repo.delete!(template)
    view |> element("#restore-template-#{template.id}") |> render_click()
    assert has_element?(view, "textarea[name='prompt_template[body]']", "Keep draft")
    assert render(view) =~ "Template no longer exists"
  end

  test "a customized body equal to the default can still opt back into updates", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{slug: "equal_restore", name: "Equal", body: "Baseline"})

    {:ok, template} = PromptTemplate.update(template, %{body: "Other"})
    {:ok, template} = PromptTemplate.update(template, %{body: "Baseline"})
    assert template.body_customized
    {:ok, view, _} = live(conn, ~p"/bo/prompt-templates")
    view |> element("#prompt-tab-equal_restore") |> render_click()
    refute has_element?(view, "#restore-template-#{template.id}[disabled]")
    view |> element("#restore-template-#{template.id}") |> render_click()
    refute PromptTemplate.get_by_slug(template.slug).body_customized
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

  test "validate updates new-template form without persisting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("#prompt-tab-new")
    |> render_click()

    html =
      view
      |> form("#prompt-template-create-form",
        prompt_template: %{
          slug: "draft_validate",
          name: "Draft Validate",
          description: "draft",
          body: "Draft body"
        }
      )
      |> render_change()

    assert html =~ "draft_validate"
    assert html =~ "Draft Validate"
    assert PromptTemplate.get_by_slug("draft_validate") == nil
  end

  test "validate updates existing-template form without saving", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{
        slug: "lane6_validate",
        name: "Lane 6 Validate",
        description: "before",
        body: "old body",
        active: true
      })

    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("button[phx-click='switch_tab'][phx-value-id='#{template.id}']")
    |> render_click()

    html =
      view
      |> form("#prompt-template-edit-form-#{template.id}",
        prompt_template: %{
          id: template.id,
          name: "Lane 6 Draft",
          description: "after",
          body: "new body"
        }
      )
      |> render_change()

    assert html =~ "Lane 6 Draft"
    assert PromptTemplate.get_by_slug("lane6_validate").name == "Lane 6 Validate"
  end

  test "toggles body preview for existing template markdown", %{conn: conn} do
    {:ok, template} =
      PromptTemplate.create(%{
        slug: "lane6_preview",
        name: "Lane 6 Preview",
        description: "preview",
        body: "# Preview body",
        active: true
      })

    {:ok, view, _html} = live(conn, ~p"/bo/prompt-templates")

    view
    |> element("button[phx-click='switch_tab'][phx-value-id='#{template.id}']")
    |> render_click()

    html =
      view
      |> element("button[phx-click='toggle_body_preview'][phx-value-mode='preview']", "Preview")
      |> render_click()

    assert html =~ ~s(id="prompt-template-body-#{template.id}-preview")
    assert html =~ "Preview body</h1>"

    html =
      view
      |> element("button[phx-click='toggle_body_preview'][phx-value-mode='write']", "Write")
      |> render_click()

    refute html =~ ~s(id="prompt-template-body-#{template.id}-preview")
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
