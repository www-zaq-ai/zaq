defmodule ZaqWeb.Live.BO.System.SystemConfigLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{email: "admin@example.com", username: "testadmin_sc"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  describe "mount" do
    test "renders the telemetry configuration form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/system-config")
      assert html =~ "Telemetry Collection"
      assert html =~ "telemetry-config-form"
    end
  end

  describe "telemetry validate" do
    test "updates form without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      html =
        view
        |> form("#telemetry-config-form", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "250",
            "repo_query_duration_threshold_ms" => "15",
            "no_answer_alert_threshold_percent" => "10",
            "conversation_response_sla_ms" => "1500"
          }
        })
        |> render_change()

      assert html =~ "250"
      assert html =~ "15"

      assert Zaq.System.get_config("telemetry.request_duration_threshold_ms") == nil
      assert Zaq.System.get_config("telemetry.repo_query_duration_threshold_ms") == nil
      assert Zaq.System.get_config("telemetry.no_answer_alert_threshold_percent") == nil
      assert Zaq.System.get_config("telemetry.conversation_response_sla_ms") == nil
    end
  end

  describe "telemetry save" do
    test "persists all telemetry settings to the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> form("#telemetry-config-form", %{
        "telemetry_config" => %{
          "capture_infra_metrics" => "false",
          "request_duration_threshold_ms" => "300",
          "repo_query_duration_threshold_ms" => "25",
          "no_answer_alert_threshold_percent" => "11",
          "conversation_response_sla_ms" => "1600"
        }
      })
      |> render_submit()

      assert Zaq.System.get_config("telemetry.capture_infra_metrics") == "false"
      assert Zaq.System.get_config("telemetry.request_duration_threshold_ms") == "300"
      assert Zaq.System.get_config("telemetry.repo_query_duration_threshold_ms") == "25"
      assert Zaq.System.get_config("telemetry.no_answer_alert_threshold_percent") == "11"
      assert Zaq.System.get_config("telemetry.conversation_response_sla_ms") == "1600"
    end
  end
end
