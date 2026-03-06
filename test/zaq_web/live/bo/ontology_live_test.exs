# defmodule ZaqWeb.Live.BO.OntologyLiveTest do
#   @moduledoc """
#   Tests for the BackOffice Ontology LiveView.

#   These tests require the ontology license to be loaded so that all
#   LicenseManager.Paid.Ontology.* modules are available at runtime.

#   Prerequisites (in test_helper.exs or test setup):
#     - Feature.seed!()
#     - License created & loaded with ontology feature
#     - Ontology migrations have run
#   """
#   use ZaqWeb.ConnCase, async: false

#   import Phoenix.LiveViewTest
#   import Zaq.AccountsFixtures

#   # ---------------------------------------------------------------------------
#   # Runtime-injected ontology modules (available only after license loads)
#   # ---------------------------------------------------------------------------
#   alias LicenseManager.Paid.Ontology.Businesses
#   alias LicenseManager.Paid.Ontology.Divisions
#   alias LicenseManager.Paid.Ontology.Departments
#   alias LicenseManager.Paid.Ontology.Teams
#   alias LicenseManager.Paid.Ontology.People
#   alias LicenseManager.Paid.Ontology.KnowledgeDomains

#   # ---------------------------------------------------------------------------
#   # Setup
#   # ---------------------------------------------------------------------------

#   setup %{conn: conn} do
#     user = super_admin_fixture()

#     conn =
#       conn
#       |> Plug.Test.init_test_session(%{})
#       |> log_in_bo_user(user)

#     {:ok, conn: conn, user: user}
#   end

#   # Adapt this to match your actual BO authentication plug.
#   # Common patterns:
#   #   - Session-based: put user_id or token in session
#   #   - Token-based: set a cookie
#   # Check your :require_authenticated_user plug implementation.
#   defp log_in_bo_user(conn, user) do
#     Plug.Test.init_test_session(conn, %{bo_user_id: user.id})
#   end

#   # ---------------------------------------------------------------------------
#   # Ontology Seed Helpers
#   # ---------------------------------------------------------------------------

#   defp seed_ontology do
#     {:ok, business} = Businesses.create(%{name: "TestCorp", slug: "testcorp"})
#     {:ok, division} = Divisions.create(%{name: "Engineering", business_id: business.id})
#     {:ok, department} = Departments.create(%{name: "Platform", division_id: division.id})
#     {:ok, team} = Teams.create(%{name: "Backend", department_id: department.id})

#     {:ok, person} =
#       People.create(%{
#         full_name: "Alice Smith",
#         email: "alice@test.com",
#         role: "Engineer",
#         status: "active"
#       })

#     {:ok, domain} =
#       KnowledgeDomains.create(%{
#         name: "Infrastructure",
#         description: "Cloud and infra",
#         keywords: ["aws", "terraform", "k8s"],
#         department_id: department.id
#       })

#     %{
#       business: business,
#       division: division,
#       department: department,
#       team: team,
#       person: person,
#       domain: domain
#     }
#   end

#   defp seed_channel(person_id) do
#     {:ok, channel} =
#       People.add_channel(%{
#         person_id: person_id,
#         platform: "mattermost",
#         channel_identifier: "@alice"
#       })

#     channel
#   end

#   defp seed_team_member(team_id, person_id) do
#     {:ok, member} =
#       Teams.add_member(%{
#         team_id: team_id,
#         person_id: person_id,
#         role_in_team: "SME"
#       })

#     member
#   end

#   # =========================================================================
#   # Mount & License Gate
#   # =========================================================================

#   describe "mount" do
#     test "renders licensed state with tabs", %{conn: conn} do
#       seed_ontology()
#       {:ok, _view, html} = live(conn, "/bo/ontology")

#       assert html =~ "Tree View" or html =~ "Feature Not Licensed"
#     end

#     test "defaults to tree_view tab", %{conn: conn} do
#       seed_ontology()
#       {:ok, _view, html} = live(conn, "/bo/ontology")

#       assert html =~ "ontology-tree"
#     end
#   end

#   # =========================================================================
#   # Tab Switching
#   # =========================================================================

#   describe "switch_tab" do
#     test "switches to org_structure tab", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")

#       html = view |> element("[phx-value-tab=org_structure]") |> render_click()
#       assert html =~ "Add Business"
#     end

#     test "switches to people tab", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")

#       html = view |> element("[phx-value-tab=people]") |> render_click()
#       assert html =~ "Add Person"
#     end

#     test "switches to knowledge_domains tab", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")

#       html = view |> element("[phx-value-tab=knowledge_domains]") |> render_click()
#       assert html =~ "Add Domain"
#     end

#     test "clears modal and selected person on tab switch", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")

#       # Go to people tab and select a person
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       # Switch tab — detail panel should disappear
#       html = view |> element("[phx-value-tab=org_structure]") |> render_click()
#       refute html =~ "alice@test.com"
#     end
#   end

#   # =========================================================================
#   # Tree Expand / Collapse
#   # =========================================================================

#   describe "toggle_node" do
#     test "expands a business node to show divisions", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       html =
#         view
#         |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]")
#         |> render_click()

#       assert html =~ "Engineering"
#     end

#     test "collapses an expanded node", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       # Expand then collapse
#       view |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]") |> render_click()
#       html = view |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]") |> render_click()

#       # Nested items should no longer be visible
#       refute html =~ "Platform"
#     end
#   end

#   # =========================================================================
#   # Business CRUD
#   # =========================================================================

#   describe "business CRUD" do
#     test "creates a business", %{conn: conn} do
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=new]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{name: "NewBiz", slug: "newbiz"})
#         |> render_submit()

#       assert html =~ "saved successfully"
#       assert html =~ "NewBiz"
#     end

#     test "validates business slug format", %{conn: conn} do
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=new]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{name: "Test", slug: "INVALID SLUG!"})
#         |> render_change()

#       assert html =~ "URL-safe" or is_binary(html)
#     end

#     test "edits a business", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=edit][phx-value-id=#{business.id}]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{name: "UpdatedCorp"})
#         |> render_submit()

#       assert html =~ "saved successfully"
#       assert html =~ "UpdatedCorp"
#     end

#     test "deletes a business", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=confirm_delete][phx-value-entity=business][phx-value-id=#{business.id}]")
#       |> render_click()

#       html = view |> element("[phx-click=delete]") |> render_click()
#       assert html =~ "deleted"
#       refute html =~ "TestCorp"
#     end
#   end

#   # =========================================================================
#   # Division CRUD
#   # =========================================================================

#   describe "division CRUD" do
#     test "creates a division", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=division][phx-value-action=new][phx-value-parent_id=#{business.id}]")
#       |> render_click()

#       html = view |> form("form", form: %{name: "Sales"}) |> render_submit()
#       assert html =~ "saved successfully"
#     end
#   end

#   # =========================================================================
#   # Department CRUD
#   # =========================================================================

#   describe "department CRUD" do
#     test "creates a department", %{conn: conn} do
#       %{business: business, division: division} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=div-#{division.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=department][phx-value-action=new][phx-value-parent_id=#{division.id}]")
#       |> render_click()

#       html = view |> form("form", form: %{name: "QA"}) |> render_submit()
#       assert html =~ "saved successfully"
#     end
#   end

#   # =========================================================================
#   # Team CRUD
#   # =========================================================================

#   describe "team CRUD" do
#     test "creates a team", %{conn: conn} do
#       %{business: business, division: division, department: department} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=biz-#{business.id}]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=div-#{division.id}]") |> render_click()
#       view |> element("[phx-click=toggle_node][phx-value-id=dept-#{department.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=team][phx-value-action=new][phx-value-parent_id=#{department.id}]")
#       |> render_click()

#       html = view |> form("form", form: %{name: "Frontend"}) |> render_submit()
#       assert html =~ "saved successfully"
#     end
#   end

#   # =========================================================================
#   # Person CRUD
#   # =========================================================================

#   describe "person CRUD" do
#     test "creates a person", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=person][phx-value-action=new]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{full_name: "Bob Jones", email: "bob@test.com", role: "Designer", status: "active"})
#         |> render_submit()

#       assert html =~ "saved successfully"
#       assert html =~ "Bob Jones"
#     end

#     test "edits a person", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=person][phx-value-action=edit][phx-value-id=#{person.id}]")
#       |> render_click()

#       html = view |> form("form", form: %{full_name: "Alice Updated"}) |> render_submit()
#       assert html =~ "saved successfully"
#     end

#     test "deletes a person", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       view
#       |> element("[phx-click=confirm_delete][phx-value-entity=person][phx-value-id=#{person.id}]")
#       |> render_click()

#       html = view |> element("[phx-click=delete]") |> render_click()
#       assert html =~ "deleted"
#     end
#   end

#   # =========================================================================
#   # Person Selection
#   # =========================================================================

#   describe "person selection" do
#     test "shows detail panel with person info", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()

#       html = view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       assert html =~ "Alice Smith"
#       assert html =~ "alice@test.com"
#       assert html =~ "Engineer"
#     end

#     test "deselect hides detail panel", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       html = view |> element("[phx-click=deselect_person]") |> render_click()
#       refute html =~ "alice@test.com"
#     end
#   end

#   # =========================================================================
#   # Channel CRUD
#   # =========================================================================

#   describe "channel CRUD" do
#     test "creates a channel for a person", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=channel][phx-value-action=new][phx-value-parent_id=#{person.id}]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{platform: "slack", channel_identifier: "@alice-slack"})
#         |> render_submit()

#       assert html =~ "saved successfully"
#     end

#     test "sets preferred channel", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       channel = seed_channel(person.id)
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       html =
#         view
#         |> element("[phx-click=set_preferred_channel][phx-value-person_id=#{person.id}][phx-value-channel_id=#{channel.id}]")
#         |> render_click()

#       assert html =~ "Preferred channel updated"
#     end

#     test "deletes a channel", %{conn: conn} do
#       %{person: person} = seed_ontology()
#       channel = seed_channel(person.id)
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       view
#       |> element("[phx-click=confirm_delete][phx-value-entity=channel][phx-value-id=#{channel.id}]")
#       |> render_click()

#       html = view |> element("[phx-click=delete]") |> render_click()
#       assert html =~ "deleted"
#     end
#   end

#   # =========================================================================
#   # Team Membership
#   # =========================================================================

#   describe "team membership" do
#     test "adds a person to a team via team_member modal", %{conn: conn} do
#       %{person: person, team: team} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=team_member][phx-value-action=new][phx-value-parent_id=#{person.id}]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{team_id: team.id, person_id: person.id, role_in_team: "Lead"})
#         |> render_submit()

#       assert html =~ "saved successfully"
#     end

#     test "removes a person from a team", %{conn: conn} do
#       %{person: person, team: team} = seed_ontology()
#       seed_team_member(team.id, person.id)
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()
#       view |> element("[phx-click=select_person][phx-value-id=#{person.id}]") |> render_click()

#       html =
#         view
#         |> element("[phx-click=remove_team_member][phx-value-team_id=#{team.id}][phx-value-person_id=#{person.id}]")
#         |> render_click()

#       assert html =~ "Removed from team"
#     end
#   end

#   # =========================================================================
#   # Knowledge Domain CRUD
#   # =========================================================================

#   describe "knowledge domain CRUD" do
#     test "creates a domain with comma-separated keywords", %{conn: conn} do
#       %{department: department} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=knowledge_domains]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=knowledge_domain][phx-value-action=new]")
#       |> render_click()

#       html =
#         view
#         |> form("form", form: %{
#           name: "DevOps",
#           description: "CI/CD and deployment",
#           keywords: "ci, cd, deploy, pipeline",
#           department_id: department.id
#         })
#         |> render_submit()

#       assert html =~ "saved successfully"
#       assert html =~ "DevOps"
#     end

#     test "keywords are trimmed and split correctly", %{conn: conn} do
#       %{department: department} = seed_ontology()

#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=knowledge_domains]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=knowledge_domain][phx-value-action=new]")
#       |> render_click()

#       view
#       |> form("form", form: %{
#         name: "Security",
#         keywords: "  auth , oauth,  tokens , jwt  ",
#         department_id: department.id
#       })
#       |> render_submit()

#       domain =
#         KnowledgeDomains.list_by_department(department.id)
#         |> Enum.find(&(&1.name == "Security"))

#       assert domain
#       assert domain.keywords == ["auth", "oauth", "tokens", "jwt"]
#     end

#     test "edits a domain", %{conn: conn} do
#       %{domain: domain} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=knowledge_domains]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=knowledge_domain][phx-value-action=edit][phx-value-id=#{domain.id}]")
#       |> render_click()

#       html = view |> form("form", form: %{name: "Cloud Infra"}) |> render_submit()
#       assert html =~ "saved successfully"
#       assert html =~ "Cloud Infra"
#     end

#     test "deletes a domain", %{conn: conn} do
#       %{domain: domain} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=knowledge_domains]") |> render_click()

#       view
#       |> element("[phx-click=confirm_delete][phx-value-entity=knowledge_domain][phx-value-id=#{domain.id}]")
#       |> render_click()

#       html = view |> element("[phx-click=delete]") |> render_click()
#       assert html =~ "deleted"
#       refute html =~ "Infrastructure"
#     end
#   end

#   # =========================================================================
#   # Modal Lifecycle
#   # =========================================================================

#   describe "modal lifecycle" do
#     test "opens new business modal", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       html =
#         view
#         |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=new]")
#         |> render_click()

#       assert html =~ "New Business"
#       assert html =~ "Create"
#     end

#     test "opens edit modal with existing data", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       html =
#         view
#         |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=edit][phx-value-id=#{business.id}]")
#         |> render_click()

#       assert html =~ "Edit Business"
#       assert html =~ "Update"
#       assert html =~ "TestCorp"
#     end

#     test "close_modal clears modal", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=open_modal][phx-value-entity=business][phx-value-action=new]")
#       |> render_click()

#       html = view |> element("[phx-click=close_modal]") |> render_click()
#       refute html =~ "New Business"
#     end

#     test "cancel_delete clears confirmation", %{conn: conn} do
#       %{business: business} = seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       view
#       |> element("[phx-click=confirm_delete][phx-value-entity=business][phx-value-id=#{business.id}]")
#       |> render_click()

#       html = view |> element("[phx-click=cancel_delete]") |> render_click()
#       refute html =~ "Confirm Delete"
#     end
#   end

#   # =========================================================================
#   # Tree View Tab
#   # =========================================================================

#   describe "tree_view tab" do
#     test "renders the JS hook container with tree data", %{conn: conn} do
#       seed_ontology()
#       {:ok, _view, html} = live(conn, "/bo/ontology")

#       assert html =~ "ontology-tree"
#       assert html =~ ~s(phx-hook="OntologyTree")
#       assert html =~ "data-tree="
#     end

#     test "tree data includes full hierarchy", %{conn: conn} do
#       %{team: team, person: person} = seed_ontology()
#       seed_team_member(team.id, person.id)

#       {:ok, _view, html} = live(conn, "/bo/ontology")

#       assert html =~ "TestCorp"
#       assert html =~ "Engineering"
#       assert html =~ "Platform"
#       assert html =~ "Backend"
#       assert html =~ "Alice Smith"
#       assert html =~ "Infrastructure"
#     end
#   end

#   # =========================================================================
#   # PubSub
#   # =========================================================================

#   describe "PubSub" do
#     test "reloads on license_updated broadcast", %{conn: conn} do
#       seed_ontology()
#       {:ok, view, _html} = live(conn, "/bo/ontology")

#       Phoenix.PubSub.broadcast(Zaq.PubSub, "license:updated", :license_updated)

#       # Allow async to process
#       :timer.sleep(100)

#       html = render(view)
#       assert is_binary(html)
#     end
#   end

#   # =========================================================================
#   # Empty States
#   # =========================================================================

#   describe "empty states" do
#     test "org_structure shows empty message when no businesses", %{conn: conn} do
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=org_structure]") |> render_click()

#       # Wait for async load
#       :timer.sleep(200)
#       html = render(view)

#       assert html =~ "No organizations configured yet"
#     end

#     test "people shows empty message when no people", %{conn: conn} do
#       {:ok, view, _html} = live(conn, "/bo/ontology")
#       view |> element("[phx-value-tab=people]") |> render_click()

#       :timer.sleep(200)
#       html = render(view)

#       assert html =~ "No people configured yet"
#     end
#   end
# end
