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

    test "hides locked-features section when all features are licensed", %{conn: conn} do
      FeatureStore.store(
        %{
          "license_key" => "lic_full_789",
          "company" => %{"name" => "Full Corp"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(120, :day) |> DateTime.to_iso8601(),
          "features" => fully_licensed_features()
        },
        [
          Zaq.Paid.Ontology,
          Zaq.Paid.KnowledgeGap,
          Zaq.Paid.Slack,
          Zaq.Paid.Email,
          Zaq.Paid.Rag,
          Zaq.Paid.Sessions
        ]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/license")
      refute html =~ "Available to Unlock"
      refute html =~ "Contact Sales to Upgrade"
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

  describe "date formatting and days-left branches" do
    setup do
      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "renders nil expiration with fallback date and neutral days class", %{conn: conn} do
      store_license(nil)

      {:ok, _view, html} = live(conn, ~p"/bo/license")

      assert html =~ "—"
      assert html =~ ~r/Days Left.*?text-black.*?days/s
    end

    test "renders invalid expiration string and neutral days class", %{conn: conn} do
      store_license("not-a-date")

      {:ok, _view, html} = live(conn, ~p"/bo/license")

      assert html =~ "not-a-date"
      assert html =~ ~r/Days Left.*?text-black.*?days/s
    end

    test "renders amber class for medium-term expiration", %{conn: conn} do
      store_license(DateTime.utc_now() |> DateTime.add(45, :day) |> DateTime.to_iso8601())

      {:ok, _view, html} = live(conn, ~p"/bo/license")

      assert html =~ ~r/Days Left.*?text-amber-600.*?days/s
    end

    test "renders green class for long-term expiration", %{conn: conn} do
      store_license(DateTime.utc_now() |> DateTime.add(140, :day) |> DateTime.to_iso8601())

      {:ok, _view, html} = live(conn, ~p"/bo/license")

      assert html =~ ~r/Days Left.*?text-emerald-600.*?days/s
    end
  end

  defp store_license(expires_at) do
    FeatureStore.store(
      %{
        "license_key" => "lic_date_coverage",
        "company" => %{"name" => "Date Corp"},
        "expires_at" => expires_at,
        "features" => [
          %{
            "name" => "Ontology Management",
            "description" => "Knowledge graph management",
            "module_tags" => ["Elixir.Zaq.Paid.Ontology"]
          }
        ]
      },
      [Zaq.Paid.Ontology]
    )
  end

  defp fully_licensed_features do
    [
      "Ontology Management",
      "Knowledge Gap Detection",
      "Slack Integration",
      "Email Channel",
      "Advanced RAG Pipeline",
      "Multi-Tenant Sessions"
    ]
    |> Enum.map(fn name ->
      %{
        "name" => name,
        "description" => "Included in enterprise plan",
        "module_tags" => []
      }
    end)
  end
end
