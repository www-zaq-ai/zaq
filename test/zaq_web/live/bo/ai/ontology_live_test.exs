defmodule ZaqWeb.Live.BO.AI.OntologyLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.License.FeatureStore

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    FeatureStore.clear()

    on_exit(fn ->
      FeatureStore.clear()
    end)

    %{conn: conn, user: user}
  end

  describe "mount licensing branches" do
    test "unlicensed when no ontology feature loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ontology")

      assert has_element?(view, "p", "Feature Not Licensed")
    end

    test "unlicensed when license exists but ontology feature missing", %{conn: conn} do
      :ok =
        FeatureStore.store(
          %{
            "license_key" => "lic_without_ontology",
            "company_name" => "Acme",
            "features" => [%{"name" => "knowledge-gap"}]
          },
          []
        )

      {:ok, view, _html} = live(conn, ~p"/bo/ontology")

      assert has_element?(view, "p", "Feature Not Licensed")
    end

    test "licensed when ontology feature exists", %{conn: conn} do
      :ok =
        FeatureStore.store(
          %{
            "license_key" => "lic_with_ontology",
            "company_name" => "Acme",
            "features" => [%{"name" => "ontology"}]
          },
          []
        )

      {:ok, view, _html} = live(conn, ~p"/bo/ontology")

      refute has_element?(view, "p", "Feature Not Licensed")
    end
  end
end
