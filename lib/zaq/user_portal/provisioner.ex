defmodule Zaq.UserPortal.Provisioner do
  @moduledoc """
  Provisions the ZAQ Provider credential from user portal onboarding results.

  This module owns the portal-specific bootstrap behavior: creating or updating
  the "ZAQ Provider" credential, and wiring first-run model configs when the
  portal returns a LiteLLM API key. It delegates all persistence to `Zaq.System`.
  """

  alias Zaq.Agent.ZAQProvider
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig

  @credential_name "ZAQ Provider"
  @description "Zaq Provider (Free Tier) gives you ability to access different models."

  @spec provision_with_key(%{litellm_api_key: String.t()}, keyword()) ::
          {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_with_key(%{litellm_api_key: api_key}, _opts \\ []) when is_binary(api_key) do
    attrs = credential_attrs(%{api_key: api_key})

    result =
      case System.get_ai_provider_credential_by_name(@credential_name) do
        nil -> System.create_ai_provider_credential(attrs)
        existing -> System.update_ai_provider_credential(existing, attrs)
      end

    case result do
      {:ok, credential} ->
        provision_system_configs(credential)
        {:ok, credential}

      error ->
        error
    end
  end

  @spec provision_without_key(keyword()) :: {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_without_key(_opts \\ []) do
    case System.get_ai_provider_credential_by_name(@credential_name) do
      nil -> System.create_ai_provider_credential(credential_attrs(%{}))
      existing -> {:ok, existing}
    end
  end

  defp credential_attrs(extra) do
    Map.merge(
      %{
        name: @credential_name,
        provider: "zaq_provider",
        endpoint: ZAQProvider.default_endpoint(),
        sovereign: false,
        description: @description
      },
      extra
    )
  end

  defp provision_system_configs(%AIProviderCredential{id: cred_id}) do
    if is_nil(System.get_llm_config().credential_id) do
      %LLMConfig{}
      |> LLMConfig.changeset(%{credential_id: cred_id, model: "owl-alpha"})
      |> System.save_llm_config()
    end

    if is_nil(System.get_embedding_config().credential_id) do
      %EmbeddingConfig{}
      |> EmbeddingConfig.changeset(%{
        credential_id: cred_id,
        model: "nvidia/llama-nemotron-embed-vl-1b-v2",
        dimension: 2048
      })
      |> System.save_embedding_config()
    end

    if is_nil(System.get_image_to_text_config().credential_id) do
      %ImageToTextConfig{}
      |> ImageToTextConfig.changeset(%{
        credential_id: cred_id,
        model: "google/gemma-4-31b-it"
      })
      |> System.save_image_to_text_config()
    end

    :ok
  end
end
