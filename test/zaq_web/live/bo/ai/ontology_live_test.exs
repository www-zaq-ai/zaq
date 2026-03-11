defmodule ZaqWeb.Live.BO.AI.OntologyLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.License.FeatureStore

  setup %{conn: conn} do
    FeatureStore.clear()

    on_exit(fn ->
      FeatureStore.clear()
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

  test "licensed tree view degrades gracefully when runtime modules are unavailable", %{
    conn: conn
  } do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])

    {:ok, view, _html} = live(conn, ~p"/bo/ontology")
    render_async(view)

    assert has_element?(view, "#ontology-tree")

    assert has_element?(
             view,
             "span",
             "Failed to load tree data. Migrations may still be running."
           )
  end

  test "switching licensed tabs stays stable without ontology runtime modules", %{conn: conn} do
    FeatureStore.store(%{"features" => [%{"name" => "ontology"}]}, [])

    {:ok, view, _html} = live(conn, ~p"/bo/ontology")
    render_async(view)

    view
    |> element("button[phx-click='switch_tab'][phx-value-tab='org_structure']")
    |> render_click()

    render_async(view)

    assert has_element?(view, "button[phx-click='open_modal'][phx-value-entity='business']")

    assert has_element?(
             view,
             "span",
             "Failed to load organization data. Migrations may still be running."
           )
  end
end
