defmodule Zaq.SystemConfigFixtures do
  @moduledoc false

  alias Zaq.System
  alias Zaq.System.{EmbeddingConfig, ImageToTextConfig, LLMConfig}

  def ai_credential_fixture(attrs \\ %{}) do
    unique = Ecto.UUID.generate()

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

    {:ok, credential} =
      params
      |> explicit_test_authentication()
      |> System.create_ai_provider_credential()

    credential
  end

  defp explicit_test_authentication(params) do
    metadata = Map.get(params, :metadata, %{})
    kind = Map.get(params, :auth_kind) || test_auth_kind(params, metadata)

    metadata =
      if params[:provider] == "openai_codex" and is_map(metadata),
        do: Map.put_new(metadata, "client_id", "test-codex-client"),
        else: metadata

    params =
      params
      |> Map.put(:auth_kind, kind)
      |> Map.put(
        :metadata,
        if(is_map(metadata), do: Map.delete(metadata, "auth_kind"), else: metadata)
      )

    params =
      if params[:provider] == "openai_codex",
        do: Map.put_new(params, :personal_credential_policy, :required),
        else: params

    if kind == "none", do: Map.delete(params, :api_key), else: params
  end

  defp test_auth_kind(%{provider: "openai_codex"}, _metadata), do: "oauth2"

  defp test_auth_kind(params, metadata) do
    declared = if is_map(metadata), do: Map.get(metadata, "auth_kind"), else: nil

    cond do
      declared in ["none", "oauth2", "api_key"] -> declared
      is_map(metadata) and Map.has_key?(metadata, "client_id") -> "oauth2"
      is_binary(params[:api_key]) and String.trim(params[:api_key]) != "" -> "api_key"
      true -> "none"
    end
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
        api_key: Map.get(attrs, :api_key, ""),
        provider: Map.get(attrs, :provider, "custom")
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
        Map.drop(attrs, [:api_key, :endpoint, :provider])
      )

    changeset = LLMConfig.changeset(%LLMConfig{}, params)
    {:ok, _} = System.save_llm_config(changeset)
    credential
  end
end
