defmodule ZaqWeb.Live.BO.System.SystemConfigLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.System

  setup %{conn: conn} do
    user = user_fixture(%{email: "admin@example.com", username: "testadmin_sc"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  describe "mount" do
    test "renders telemetry by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/system-config")
      assert html =~ "Telemetry Collection"
      assert html =~ "telemetry-config-form"
    end
  end

  describe "tab navigation" do
    test "falls back to telemetry for unknown tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/system-config?tab=unknown")
      assert html =~ "Telemetry Collection"
      refute html =~ "llm-config-form"
    end

    test "switches to AI credentials tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='ai_credentials']")
      |> render_click()

      assert_patch(view, ~p"/bo/system-config?tab=ai_credentials")
      assert has_element?(view, "#ai-credential-form", "") == false
      assert render(view) =~ "AI Credentials"
    end
  end

  describe "AI credentials" do
    test "api key field has show/hide eye controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(
               view,
               "#ai-credential-api-key-input[style*='-webkit-text-security: disc']"
             )

      assert has_element?(view, "#ai-credential-api-key-show")
      assert has_element?(view, "#ai-credential-api-key-hide.hidden")
    end

    test "creates new credential from modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")

      render_submit(view, "save_ai_credential", %{
        "ai_credential" => %{
          "name" => "OpenAI EU",
          "provider" => "openai",
          "endpoint" => "https://api.openai.com/v1",
          "api_key" => "sk-test-live",
          "sovereign" => "true",
          "description" => "EU sovereign"
        }
      })

      assert render(view) =~ "AI credential saved."
      assert render(view) =~ "OpenAI EU"
    end

    test "editing row opens modal", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "Primary",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          description: "main"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")
      assert render(view) =~ "Edit AI Credential"
      assert render(view) =~ "Primary"
    end
  end

  describe "LLM config with credential" do
    test "saves llm config using selected credential", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "LLM Credential",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      render_submit(view, "save_llm", %{
        "llm_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "gpt-4o",
          "temperature" => "0.2",
          "top_p" => "0.9",
          "supports_logprobs" => "true",
          "supports_json_mode" => "true",
          "max_context_window" => "5000",
          "distance_threshold" => "1.0",
          "path" => "/chat/completions"
        }
      })

      cfg = System.get_llm_config()
      assert cfg.credential_id == credential.id
      assert cfg.provider == "openai"
      assert cfg.endpoint == "https://api.openai.com/v1"
      assert cfg.model == "gpt-4o"
    end
  end

  describe "embedding save confirmation" do
    test "save_embedding opens and cancel closes destructive confirmation modal", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "Embedding Credential",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_unlock_embedding']")
      |> render_click()

      params = %{
        "embedding_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "different-model",
          "dimension" => "3584",
          "chunk_min_tokens" => "400",
          "chunk_max_tokens" => "900"
        }
      }

      _ = render_change(view, "validate_embedding", params)

      html = render_submit(view, "save_embedding", params)

      assert html =~ "Delete All Embeddings?"

      html =
        view
        |> element("button[phx-click='cancel_save_embedding']")
        |> render_click()

      refute html =~ "Delete All Embeddings?"
    end
  end
end
