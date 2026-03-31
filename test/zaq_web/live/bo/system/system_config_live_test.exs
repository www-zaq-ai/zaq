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

  describe "embedding validate" do
    test "interpolates max dimension validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click=\"unlock_embedding\"]")
      |> render_click()

      view
      |> element("button[phx-click=\"confirm_unlock_embedding\"]")
      |> render_click()

      html =
        view
        |> form("#embedding-config-form", %{
          "embedding_config" => %{
            "provider" => "custom",
            "model" => "bge-multilingual-gemma2",
            "endpoint" => "http://localhost:11434/v1",
            "dimension" => "4001",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })
        |> render_change()

      assert html =~ "must be less than or equal to 4000"
      refute html =~ "%{number}"
    end
  end

  describe "strict encryption errors" do
    test "shows LLM api_key encryption error in form", %{conn: conn} do
      previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='llm']")
      |> render_click()

      view
      |> form("#llm-config-form", %{
        "llm_config" => %{
          "provider" => "custom",
          "endpoint" => "https://api.openai.com/v1",
          "api_key" => "sk-llm-must-fail",
          "model" => "gpt-4o",
          "temperature" => "0.2",
          "top_p" => "0.9",
          "supports_logprobs" => "true",
          "supports_json_mode" => "true",
          "max_context_window" => "8000",
          "distance_threshold" => "1.0"
        }
      })
      |> render_submit()

      state = :sys.get_state(view.pid)
      errors = state.socket.assigns.llm_form.source.errors
      assert {:api_key, {message, _opts}} = List.keyfind(errors, :api_key, 0)
      assert message =~ "could not be encrypted"
    end

    test "shows Embedding api_key encryption error in form", %{conn: conn} do
      previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_unlock_embedding']")
      |> render_click()

      view
      |> form("#embedding-config-form", %{
        "embedding_config" => %{
          "provider" => "custom",
          "endpoint" => "http://localhost:11434/v1",
          "api_key" => "embedding-must-fail",
          "model" => "bge-multilingual-gemma2",
          "dimension" => "3584",
          "chunk_min_tokens" => "400",
          "chunk_max_tokens" => "900"
        }
      })
      |> render_submit()

      state = :sys.get_state(view.pid)
      errors = state.socket.assigns.embedding_form.source.errors
      assert {:api_key, {message, _opts}} = List.keyfind(errors, :api_key, 0)
      assert message =~ "could not be encrypted"
    end

    test "shows Image-to-Text api_key encryption error in form", %{conn: conn} do
      previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='image_to_text']")
      |> render_click()

      view
      |> form("#image-to-text-config-form", %{
        "image_to_text_config" => %{
          "provider" => "custom",
          "endpoint" => "https://api.openai.com/v1",
          "api_key" => "image-must-fail",
          "model" => "gpt-4o"
        }
      })
      |> render_submit()

      state = :sys.get_state(view.pid)
      errors = state.socket.assigns.image_to_text_form.source.errors
      assert {:api_key, {message, _opts}} = List.keyfind(errors, :api_key, 0)
      assert message =~ "could not be encrypted"
    end
  end
end
