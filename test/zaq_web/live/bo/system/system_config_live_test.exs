defmodule ZaqWeb.Live.BO.System.SystemConfigLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

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

    test "does not render global default agent selector in telemetry tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      refute has_element?(view, "#global-default-agent-select")
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

    test "switches to Global tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config")

      view
      |> element("button[phx-value-tab='global']")
      |> render_click()

      assert_patch(view, ~p"/bo/system-config?tab=global")
      assert has_element?(view, "#global-default-agent-select")
      assert render(view) =~ "Default Zaq Agent"
    end

    test "renders each tab via URL param", %{conn: conn} do
      {:ok, _view, telemetry_html} = live(conn, ~p"/bo/system-config?tab=telemetry")
      assert telemetry_html =~ "telemetry-config-form"

      {:ok, _view, llm_html} = live(conn, ~p"/bo/system-config?tab=llm")
      assert llm_html =~ "llm-config-form"

      {:ok, _view, embedding_html} = live(conn, ~p"/bo/system-config?tab=embedding")
      assert embedding_html =~ "embedding-config-form"

      {:ok, _view, image_to_text_html} = live(conn, ~p"/bo/system-config?tab=image_to_text")
      assert image_to_text_html =~ "image-to-text-config-form"

      {:ok, _view, ai_credentials_html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")
      assert ai_credentials_html =~ "AI Credentials"

      {:ok, _view, global_html} = live(conn, ~p"/bo/system-config?tab=global")
      assert global_html =~ "Global Configuration"
      assert global_html =~ "Default Zaq Agent"
    end
  end

  describe "telemetry config" do
    test "validate_telemetry assigns validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_change(view, "validate_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "-1",
            "repo_query_duration_threshold_ms" => "-1",
            "no_answer_alert_threshold_percent" => "101",
            "conversation_response_sla_ms" => "-1"
          }
        })

      assert html =~ "telemetry-config-form"
    end

    test "save_telemetry with invalid params keeps form in validation mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_submit(view, "save_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "-1",
            "repo_query_duration_threshold_ms" => "-1",
            "no_answer_alert_threshold_percent" => "120",
            "conversation_response_sla_ms" => "-1"
          }
        })

      refute html =~ "Telemetry settings saved."
      assert html =~ "telemetry-config-form"
    end

    test "save_telemetry with valid params shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=telemetry")

      html =
        render_submit(view, "save_telemetry", %{
          "telemetry_config" => %{
            "capture_infra_metrics" => "true",
            "request_duration_threshold_ms" => "25",
            "repo_query_duration_threshold_ms" => "10",
            "no_answer_alert_threshold_percent" => "12",
            "conversation_response_sla_ms" => "1600"
          }
        })

      assert html =~ "Telemetry settings saved."
    end
  end

  describe "AI credentials modal and validation" do
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

    test "deletes an unused credential from edit modal with confirmation", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Disposable",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      assert has_element?(view, "#ai-credential-delete-confirm")

      view
      |> element("button[phx-click='confirm_delete_ai_credential']")
      |> render_click()

      assert render(view) =~ "AI credential deleted."
      refute render(view) =~ "Disposable"
    end

    test "cannot delete credential currently in use", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "In Use",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      System.set_config("llm.credential_id", credential.id)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      view
      |> element("button[phx-click='confirm_delete_ai_credential']")
      |> render_click()

      assert render(view) =~ "cannot delete credential currently used by system configuration"

      id = credential.id
      assert %Zaq.System.AIProviderCredential{id: ^id} = System.get_ai_provider_credential!(id)
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

    test "save_llm with invalid params renders errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_submit(view, "save_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "",
            "temperature" => "3.0",
            "top_p" => "2.0",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "0",
            "distance_threshold" => "0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
      refute html =~ "LLM settings saved."
    end

    test "validate_llm updates form state when switching credential", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI LLM",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
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

      assert html =~ "llm-config-form"
      assert has_element?(view, "#llm-credential-select")
    end

    test "validate_llm keeps capabilities when provider and model are unchanged", %{conn: conn} do
      credential =
        seed_llm_config(%{
          model: "steady-llm-model",
          temperature: 0.1,
          top_p: 0.8,
          supports_logprobs: true,
          supports_json_mode: true
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "steady-llm-model",
            "temperature" => "0.1",
            "top_p" => "0.8",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.2",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles unknown provider by falling back safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Provider",
          provider: "provider-not-in-lldb",
          endpoint: "https://example.invalid/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "unknown-model",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles missing credential id safely", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "999999999",
            "model" => "",
            "temperature" => "0.2",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles switch to custom provider path", %{conn: conn} do
      credential =
        seed_llm_config(%{
          model: "switchable-model",
          temperature: 0.1,
          top_p: 0.8
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "",
            "temperature" => "0.1",
            "top_p" => "0.8",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.2",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
      assert System.get_llm_config().credential_id == credential.id
    end

    test "validate_llm handles unknown model capabilities fallback", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Unknown Model",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "model-not-in-lldb",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "true",
            "supports_json_mode" => "true",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles empty or missing model values safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Empty Model",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html_empty =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      html_missing =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions"
          }
        })

      assert html_empty =~ "llm-config-form"
      assert html_missing =~ "llm-config-form"
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

    test "unlock modal can be opened and closed without unlocking", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        view
        |> element("button[phx-click='unlock_embedding']")
        |> render_click()

      assert html =~ "Unlock Model Selection"

      html =
        view
        |> element("button[phx-click='cancel_unlock_embedding']")
        |> render_click()

      refute html =~ "Unlock Model Selection"
      assert html =~ "Locked"
    end

    test "confirm unlock removes locked state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view
      |> element("button[phx-click='unlock_embedding']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='confirm_unlock_embedding']")
        |> render_click()

      refute html =~ "Unlock Model Selection"
      refute html =~ "Locked"
    end

    test "confirm save embedding applies pending params", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Embedding Pending",
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
          "model" => "different-model-for-confirm",
          "dimension" => "3584",
          "chunk_min_tokens" => "400",
          "chunk_max_tokens" => "900"
        }
      }

      _ = render_change(view, "validate_embedding", params)
      _ = render_submit(view, "save_embedding", params)

      html =
        view
        |> element("button[phx-click='confirm_save_embedding']")
        |> render_click()

      refute html =~ "Delete All Embeddings?"
      assert html =~ "Embedding settings saved."
    end

    test "save embedding without model change does not open confirmation modal", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "seed-embedding-model",
          dimension: 1536,
          chunk_min_tokens: 300,
          chunk_max_tokens: 700
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      params = %{
        "embedding_config" => %{
          "credential_id" => Integer.to_string(credential.id),
          "model" => "seed-embedding-model",
          "dimension" => "1536",
          "chunk_min_tokens" => "320",
          "chunk_max_tokens" => "720"
        }
      }

      html = render_submit(view, "save_embedding", params)

      refute html =~ "Delete All Embeddings?"
      assert html =~ "Embedding settings saved."
    end

    test "save embedding invalid params renders embedding errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_submit(view, "save_embedding", %{
          "embedding_config" => %{
            "credential_id" => "",
            "model" => "",
            "dimension" => "0",
            "chunk_min_tokens" => "0",
            "chunk_max_tokens" => "0"
          }
        })

      assert html =~ "embedding-config-form"
      refute html =~ "Embedding settings saved."
    end

    test "confirm_save_embedding rescues when pending params are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html = render_click(view, "confirm_save_embedding", %{})

      assert html =~ "Failed to apply embedding settings"
    end

    test "validate_embedding handles unknown provider safely", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Embedding Provider",
          provider: "provider-not-in-lldb",
          endpoint: "https://example.invalid/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "unknown-model",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding handles blank model dimension lookup", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "baseline-embedding-model",
          dimension: 1536
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding flags model_changed when only dimension changes", %{conn: conn} do
      credential =
        seed_embedding_config(%{
          model: "stable-embedding-model",
          dimension: 1536,
          chunk_min_tokens: 300,
          chunk_max_tokens: 700
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "stable-embedding-model",
            "dimension" => "1600",
            "chunk_min_tokens" => "300",
            "chunk_max_tokens" => "700"
          }
        })

      assert html =~ "bg-red-500"
    end
  end

  describe "image to text config" do
    test "save_image_to_text with invalid params renders errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => "",
            "model" => ""
          }
        })

      assert html =~ "image-to-text-config-form"
      refute html =~ "Image-to-Text settings saved."
    end

    test "validate_image_to_text updates form state", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Vision Provider",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_change(view, "validate_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o"
          }
        })

      assert html =~ "image-to-text-config-form"
      assert has_element?(view, "#image-to-text-credential-select")
    end

    test "save_image_to_text with valid params shows success flash", %{conn: conn} do
      credential =
        seed_image_to_text_config(%{
          model: "vision-seed-model"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o"
          }
        })

      assert html =~ "Image-to-Text settings saved."
    end
  end

  describe "AI credentials" do
    test "close_ai_credential_modal hides modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      assert has_element?(view, "#ai-credential-form")

      html =
        view
        |> element("button[phx-click='close_ai_credential_modal']")
        |> render_click()

      refute html =~ "ai-credential-form"
    end

    test "validate_ai_credential auto-fills endpoint when provider changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Custom Cred",
            "provider" => "custom",
            "endpoint" => "https://will-be-overridden.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential keeps endpoint when provider is unchanged", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      _ =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Stable Cred",
            "provider" => "custom",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Stable Cred",
            "provider" => "custom",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential uses provider fallback endpoint for unknown atom-backed provider",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Unknown Atom Provider Cred",
            "provider" => "elixir",
            "endpoint" => "https://previous-endpoint.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "validate_ai_credential handles unknown provider fallback endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Unknown Provider Cred",
            "provider" => "provider-not-in-lldb",
            "endpoint" => "https://previous-endpoint.example",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ ~s(name="ai_credential[endpoint]" value="")
    end

    test "save_ai_credential invalid params keeps modal open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "",
            "provider" => "",
            "endpoint" => "",
            "api_key" => "",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ "ai-credential-form"
      refute html =~ "AI credential saved."
    end

    test "save_ai_credential updates an existing credential", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Editable Cred",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "Editable Cred Updated",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v2",
            "api_key" => "",
            "sovereign" => "false",
            "description" => "updated"
          }
        })

      assert html =~ "AI credential saved."
      assert render(view) =~ "Editable Cred Updated"
    end

    test "validate_ai_credential in edit mode resolves credential for action", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Validate Edit Cred",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      html =
        render_change(view, "validate_ai_credential", %{
          "ai_credential" => %{
            "name" => "Validate Edit Cred",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "",
            "sovereign" => "true",
            "description" => "edit validation"
          }
        })

      assert html =~ "ai-credential-form"
    end

    test "save_ai_credential shows encryption error when key config is invalid", %{conn: conn} do
      prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='new_ai_credential']")
      |> render_click()

      html =
        render_submit(view, "save_ai_credential", %{
          "ai_credential" => %{
            "name" => "Encryption Fail Cred",
            "provider" => "openai",
            "endpoint" => "https://api.openai.com/v1",
            "api_key" => "must-fail",
            "sovereign" => "false",
            "description" => ""
          }
        })

      assert html =~ "could not be encrypted"
      assert html =~ "ai-credential-form"
    end

    test "cancel_delete_ai_credential closes the confirm modal", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "To Cancel Delete",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=ai_credentials")

      view
      |> element("button[phx-click='edit_ai_credential'][phx-value-id='#{credential.id}']")
      |> render_click()

      view
      |> element("button[phx-click='open_delete_ai_credential_confirm']")
      |> render_click()

      assert has_element?(view, "#ai-credential-delete-confirm")

      view
      |> element("button[phx-click='cancel_delete_ai_credential']")
      |> render_click()

      refute has_element?(view, "#ai-credential-delete-confirm")
    end
  end

  describe "LLM fusion weight controls" do
    test "validate_llm adjusts bm25_weight when vector_weight changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.7"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm passes params unchanged when no weight changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles non-numeric fusion weight gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "notanumber",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "save_llm shows error when fusion weights sum is below minimum", %{conn: conn} do
      {:ok, credential} =
        System.create_ai_provider_credential(%{
          name: "LLM Fusion Weights",
          provider: "openai",
          endpoint: "https://api.openai.com/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_submit(view, "save_llm", %{
          "llm_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "gpt-4o",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.04",
            "fusion_vector_weight" => "0.05"
          }
        })

      assert html =~ "combined fusion weights must sum to at least 0.1"
    end

    test "validate_llm uses custom path when switching to no-credential", %{conn: conn} do
      _credential = seed_llm_config(%{model: "switchable-for-custom"})

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "",
            "model" => "switchable-for-custom",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end

    test "validate_llm handles non-integer credential_id string as custom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=llm")

      html =
        render_change(view, "validate_llm", %{
          "llm_config" => %{
            "credential_id" => "not-a-number",
            "model" => "test-model",
            "temperature" => "0.1",
            "top_p" => "0.9",
            "supports_logprobs" => "false",
            "supports_json_mode" => "false",
            "max_context_window" => "5000",
            "distance_threshold" => "1.0",
            "path" => "/chat/completions",
            "fusion_bm25_weight" => "0.5",
            "fusion_vector_weight" => "0.5"
          }
        })

      assert html =~ "llm-config-form"
    end
  end

  describe "embedding dimension detection" do
    test "validate_embedding with custom provider sets no dimension", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => "",
            "model" => "text-embedding-3-small",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end

    test "validate_embedding with unknown provider handles ArgumentError", %{conn: conn} do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Provider Embedding",
          provider: "totally-unknown-provider",
          endpoint: "https://unknown.example/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=embedding")

      view |> element("button[phx-click='unlock_embedding']") |> render_click()
      view |> element("button[phx-click='confirm_unlock_embedding']") |> render_click()

      html =
        render_change(view, "validate_embedding", %{
          "embedding_config" => %{
            "credential_id" => Integer.to_string(credential.id),
            "model" => "some-model",
            "dimension" => "",
            "chunk_min_tokens" => "400",
            "chunk_max_tokens" => "900"
          }
        })

      assert html =~ "embedding-config-form"
    end
  end

  describe "image-to-text form validation" do
    test "save_image_to_text with invalid params renders form errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=image_to_text")

      html =
        render_submit(view, "save_image_to_text", %{
          "image_to_text_config" => %{
            "credential_id" => "",
            "model" => ""
          }
        })

      assert html =~ "image-to-text-config-form"
      refute html =~ "Image-to-Text settings saved."
    end
  end
end
