defmodule ZaqWeb.Live.BO.System.LicenseLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts
  alias Zaq.License.FeatureStore

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  describe "no license" do
    setup do
      FeatureStore.clear()
      :ok
    end

    test "shows marketing page when no license loaded", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Unlock the full power of ZAQ"
      assert html =~ "Request a License"
      assert html =~ "Available with a License"
    end

    test "shows feature cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Ontology Management"
      assert html =~ "Knowledge Gap Detection"
      assert html =~ "Slack Integration"
    end

    test "shows contact sales CTA", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Contact Sales"
      assert html =~ "sales@zaq.ai"
    end
  end

  describe "with license" do
    setup do
      FeatureStore.store(
        %{
          "license_key" => "lic_test_123",
          "company" => %{"name" => "Acme Corp"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601(),
          "features" => [
            %{
              "name" => "Ontology Management",
              "description" => "Knowledge graph management",
              "module_tags" => ["Elixir.Zaq.Paid.Ontology"]
            },
            %{
              "name" => "Knowledge Gap Detection",
              "description" => "Find missing info",
              "module_tags" => ["Elixir.Zaq.Paid.KnowledgeGap"]
            }
          ]
        },
        [Zaq.Paid.Ontology, Zaq.Paid.KnowledgeGap]
      )

      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "shows license info", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "License Active"
      assert html =~ "lic_test_123"
      assert html =~ "Acme Corp"
    end

    test "shows licensed features", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Ontology Management"
      assert html =~ "Knowledge Gap Detection"
    end

    test "shows loaded module count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Loaded Modules"
      assert html =~ "2"
    end

    test "shows days left", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Days Left"
      assert html =~ "days"
    end

    test "shows locked features for upgrade", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "Available to Unlock"
      assert html =~ "Slack Integration"
      assert html =~ "Locked"
    end
  end

  describe "expired license" do
    setup do
      FeatureStore.store(
        %{
          "license_key" => "lic_expired_456",
          "company_name" => "Expired Corp",
          "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_iso8601(),
          "features" => [
            %{
              "name" => "Ontology Management",
              "description" => "Knowledge graph",
              "module_tags" => []
            }
          ]
        },
        []
      )

      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "shows red days left for expired license", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/license")
      assert html =~ "text-red-600"
    end
  end
end
