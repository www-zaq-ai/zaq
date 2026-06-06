defmodule ZaqWeb.Live.BO.AI.KnowledgeGapLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Addons.FeatureStore

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

  test "enables the feature gate after addons_updated when knowledge_gap becomes available", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/knowledge-gap")

    assert has_element?(view, "p", "Feature Not Enabled")

    :ok =
      FeatureStore.store(
        %{
          "company_name" => "Acme",
          "license_key" => "lic-knowledge-gap-enabled",
          "features" => [%{"name" => "knowledge_gap"}]
        },
        []
      )

    Phoenix.PubSub.broadcast(Zaq.PubSub, "addons:updated", :addons_updated)

    render(view)

    refute has_element?(view, "p", "Feature Not Enabled")
  end

  test "shows the feature gate again after addons_updated when knowledge_gap is removed", %{
    conn: conn
  } do
    :ok =
      FeatureStore.store(
        %{
          "company_name" => "Acme",
          "license_key" => "lic-knowledge-gap-disabled",
          "features" => [%{"name" => "knowledge_gap"}]
        },
        []
      )

    {:ok, view, _html} = live(conn, ~p"/bo/knowledge-gap")

    refute has_element?(view, "p", "Feature Not Enabled")

    FeatureStore.clear()
    Phoenix.PubSub.broadcast(Zaq.PubSub, "addons:updated", :addons_updated)

    render(view)

    assert has_element?(view, "p", "Feature Not Enabled")
  end
end
