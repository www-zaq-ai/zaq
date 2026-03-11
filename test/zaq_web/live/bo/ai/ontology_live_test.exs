defmodule ZaqWeb.Live.BO.AI.OntologyLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.License.FeatureStore
  alias ZaqWeb.Live.BO.AI.OntologyLive

  setup %{conn: conn} do
    FeatureStore.clear()

    ontology_live_env = [
      repo: Zaq.TestSupport.OntologyFake.Repo,
      contexts: %{
        businesses: LicenseManager.Paid.Ontology.Businesses,
        divisions: LicenseManager.Paid.Ontology.Divisions,
        departments: LicenseManager.Paid.Ontology.Departments,
        teams: LicenseManager.Paid.Ontology.Teams,
        people: LicenseManager.Paid.Ontology.People,
        knowledge_domains: LicenseManager.Paid.Ontology.KnowledgeDomains
      },
      schemas: %{
        business: LicenseManager.Paid.Ontology.Business,
        division: LicenseManager.Paid.Ontology.Division,
        department: LicenseManager.Paid.Ontology.Department,
        team: LicenseManager.Paid.Ontology.Team,
        person: LicenseManager.Paid.Ontology.Person,
        channel: LicenseManager.Paid.Ontology.Channel,
        team_member: LicenseManager.Paid.Ontology.TeamMember,
        knowledge_domain: LicenseManager.Paid.Ontology.KnowledgeDomain
      }
    ]

    Application.put_env(:zaq, OntologyLive, ontology_live_env)

    on_exit(fn ->
      FeatureStore.clear()
      Application.delete_env(:zaq, OntologyLive)
    end)

    user = user_fixture(%{username: "ontology_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "renders unlicensed state when ontology feature is absent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    assert has_element?(view, "p", "Feature Not Licensed")
    refute has_element?(view, "#ontology-tree")
  end

  test "switch_tab supports valid and invalid tabs", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")
    render_async(view)

    render_hook(view, "switch_tab", %{"tab" => "org_structure"})
    render_async(view)
    assert has_element?(view, "button[phx-value-entity='business']")

    render_hook(view, "switch_tab", %{"tab" => "ok"})
    assert has_element?(view, "button[phx-value-entity='business']")
  end

  test "toggle_node adds and removes expanded state", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "org_structure"})
    render_async(view)

    refute has_element?(view, "p", "Core Division")

    render_hook(view, "toggle_node", %{"id" => "biz-1"})
    assert has_element?(view, "p", "Core Division")

    render_hook(view, "toggle_node", %{"id" => "biz-1"})
    refute has_element?(view, "p", "Core Division")
  end

  test "open_modal close_modal validate and save success/error", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "org_structure"})
    render_async(view)

    render_hook(view, "open_modal", %{"action" => "new", "entity" => "business"})
    assert has_element?(view, "h2", "New Business")

    html =
      render_change(element(view, "form[phx-submit='save']"), %{
        "form" => %{"name" => "Validated Name", "slug" => "validated-slug"}
      })

    assert html =~ "Validated Name"

    render_hook(view, "close_modal", %{})
    refute has_element?(view, "h2", "New Business")

    render_hook(view, "open_modal", %{"action" => "new", "entity" => "business"})

    render_submit(element(view, "form[phx-submit='save']"), %{
      "form" => %{"name" => "New Business", "slug" => "new-business"}
    })

    render_async(view)
    assert has_element?(view, "span", "Business saved successfully.")

    render_hook(view, "open_modal", %{"action" => "new", "entity" => "business"})

    render_submit(element(view, "form[phx-submit='save']"), %{
      "form" => %{"name" => "", "slug" => "invalid"}
    })

    assert has_element?(view, "p", "Name can't be blank")
  end

  test "confirm_delete cancel_delete and delete success/error", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "org_structure"})
    render_async(view)

    render_hook(view, "confirm_delete", %{"entity" => "business", "id" => "1"})
    assert has_element?(view, "h3", "Confirm Delete")

    render_hook(view, "cancel_delete", %{})
    refute has_element?(view, "h3", "Confirm Delete")

    render_hook(view, "confirm_delete", %{"entity" => "business", "id" => "1"})
    render_hook(view, "delete", %{})
    render_async(view)
    assert has_element?(view, "span", "Business deleted.")

    render_hook(view, "confirm_delete", %{"entity" => "business", "id" => "err-delete"})
    render_hook(view, "delete", %{})
    assert has_element?(view, "span", "Delete failed: Name cannot be deleted")
  end

  test "select_person and deselect_person", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "people"})
    render_async(view)

    render_hook(view, "select_person", %{"id" => "person-1"})
    assert has_element?(view, "p", "alice@example.test")

    render_hook(view, "deselect_person", %{})
    refute has_element?(view, "button[phx-click='deselect_person']")
  end

  test "set_preferred_channel success and error", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "people"})
    render_async(view)
    render_hook(view, "select_person", %{"id" => "person-1"})

    render_hook(view, "set_preferred_channel", %{
      "person_id" => "person-1",
      "channel_id" => "chan-2"
    })

    assert has_element?(view, "span", "Preferred channel updated.")

    render_hook(view, "set_preferred_channel", %{
      "person_id" => "person-1",
      "channel_id" => "bad"
    })

    assert has_element?(view, "span", "Failed to update preferred channel.")
  end

  test "add_team_member and remove_team_member success and error", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "people"})
    render_async(view)
    render_hook(view, "select_person", %{"id" => "person-1"})

    render_hook(view, "add_team_member", %{
      "form" => %{"team_id" => "team-1", "person_id" => "person-1", "role_in_team" => "SME"}
    })

    assert has_element?(view, "span", "Team membership added.")

    render_hook(view, "add_team_member", %{
      "form" => %{"team_id" => "error", "person_id" => "person-1"}
    })

    assert has_element?(view, "span", "Failed to add team membership. May already exist.")

    render_hook(view, "remove_team_member", %{"team_id" => "team-1", "person_id" => "person-1"})
    assert has_element?(view, "span", "Removed from team.")

    render_hook(view, "remove_team_member", %{"team_id" => "error", "person_id" => "person-1"})
    assert has_element?(view, "span", "Failed to remove team membership.")
  end

  test "knowledge domain and channel edit flows exercise update and delete paths", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "knowledge_domains"})
    render_async(view)
    assert has_element?(view, "p", "Billing")

    render_hook(view, "open_modal", %{"action" => "new", "entity" => "knowledge_domain"})

    render_submit(element(view, "form[phx-submit='save']"), %{
      "form" => %{
        "name" => "Routing",
        "department_id" => "100",
        "keywords" => "llm, routes"
      }
    })

    render_async(view)
    assert has_element?(view, "span", "Knowledge Domain saved successfully.")

    render_hook(view, "switch_tab", %{"tab" => "people"})
    render_async(view)
    render_hook(view, "select_person", %{"id" => "person-1"})

    render_hook(view, "open_modal", %{"action" => "edit", "entity" => "channel", "id" => "chan-1"})

    render_submit(element(view, "form[phx-submit='save']"), %{
      "form" => %{"platform" => "email", "channel_identifier" => "alice+updated@example.test"}
    })

    render_async(view)
    assert has_element?(view, "span", "Channel saved successfully.")

    render_hook(view, "confirm_delete", %{"entity" => "channel", "id" => "chan-1"})
    render_hook(view, "delete", %{})
    render_async(view)
    assert has_element?(view, "span", "Channel deleted.")
  end

  test "team_member save flow refreshes selected person branch", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")

    render_hook(view, "switch_tab", %{"tab" => "people"})
    render_async(view)
    render_hook(view, "select_person", %{"id" => "person-1"})

    render_hook(view, "open_modal", %{
      "action" => "new",
      "entity" => "team_member",
      "parent_id" => "person-1"
    })

    render_submit(element(view, "form[phx-submit='save']"), %{
      "form" => %{"team_id" => "team-1", "person_id" => "person-1", "role_in_team" => "Lead"}
    })

    render_async(view)
    assert has_element?(view, "span", "Team Membership saved successfully.")
  end

  test "license_updated handles true and false branches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ontology")
    assert has_element?(view, "p", "Feature Not Licensed")

    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])
    send(view.pid, :license_updated)
    render_async(view)
    assert has_element?(view, "#ontology-tree")

    FeatureStore.clear()
    send(view.pid, :license_updated)
    refute has_element?(view, "#ontology-tree")
    assert has_element?(view, "p", "Feature Not Licensed")
  end

  test "async exit fallback branch sets default error" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:loading, true)
      |> Phoenix.Component.assign(:error, nil)

    {:noreply, socket} = OntologyLive.handle_async(:load_tree_view, {:exit, :boom}, socket)

    refute socket.assigns.loading
    assert socket.assigns.error == "An unexpected error occurred while loading data."
  end
end
