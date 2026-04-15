defmodule Zaq.SystemConfigFixtures do
  @moduledoc false

  alias Zaq.System
  alias Zaq.System.{EmbeddingConfig, ImageToTextConfig, LLMConfig}

  def ai_credential_fixture(attrs \\ %{}) do
    unique = :erlang.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "Test Credential #{unique}",
          provider: "custom",
          endpoint: "http://localhost:11434/v1",
          sovereign: false
        },
        attrs
      )

    {:ok, credential} = System.create_ai_provider_credential(params)
    credential
  end

  def seed_embedding_config(attrs \\ %{}) do
    credential =
      ai_credential_fixture(%{
        endpoint: Map.get(attrs, :endpoint, "http://localhost:11434/v1"),
        api_key: Map.get(attrs, :api_key, "")
      })

    params =
      Map.merge(
        %{
          credential_id: credential.id,
          model: "test-model",
          dimension: 1536
        },
        Map.drop(attrs, [:api_key, :endpoint])
      )

    changeset = EmbeddingConfig.changeset(%EmbeddingConfig{}, params)
    {:ok, _} = System.save_embedding_config(changeset)
    credential
  end

  def seed_image_to_text_config(attrs \\ %{}) do
    credential =
      ai_credential_fixture(%{
        endpoint: Map.get(attrs, :endpoint, "http://localhost:11434/v1"),
        api_key: Map.get(attrs, :api_key, "")
      })

    params =
      Map.merge(
        %{
          credential_id: credential.id,
          model: "test-model"
        },
        Map.drop(attrs, [:api_key, :endpoint])
      )

    changeset = ImageToTextConfig.changeset(%ImageToTextConfig{}, params)
    {:ok, _} = System.save_image_to_text_config(changeset)
    credential
  end

  def seed_llm_config(attrs \\ %{}) do
    credential =
      ai_credential_fixture(%{
        endpoint: Map.get(attrs, :endpoint, "http://localhost:11434/v1"),
        api_key: Map.get(attrs, :api_key, "")
      })

    params =
      Map.merge(
        %{
          credential_id: credential.id,
          model: "test-model",
          temperature: 0.0,
          top_p: 0.9,
          supports_logprobs: false,
          supports_json_mode: false,
          max_context_window: 5000,
          distance_threshold: 1.2
        },
        Map.drop(attrs, [:api_key, :endpoint])
      )

    changeset = LLMConfig.changeset(%LLMConfig{}, params)
    {:ok, _} = System.save_llm_config(changeset)
    credential
  end
end
