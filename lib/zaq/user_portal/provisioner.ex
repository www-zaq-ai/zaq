defmodule Zaq.UserPortal.Provisioner do
  @moduledoc """
  Provisions the ZAQ Router credential from user portal onboarding results.

  This module owns the portal-specific bootstrap behavior: creating or updating
  the "ZAQ Router" credential, and wiring first-run model configs when the
  portal returns a LiteLLM API key. It delegates all persistence to `Zaq.System`.
  """

  alias Zaq.Agent.ZAQProvider
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig

  require Logger

  @credential_name "ZAQ Router"
  @description "ZAQ Router gives you the ability to access different models."

  @doc """
  Calls the portal to onboard the user by email and provisions the ZAQ credential
  with the returned API key. Returns `{:ok, credential}` or `{:error, reason}`.
  """
  @spec provision_for_user(String.t()) :: {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_for_user(email) when is_binary(email) do
    case client().onboard_user(email) do
      {:ok, litellm} -> provision_with_key(litellm)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates the "ZAQ Router" credential with no API key, used when the portal is
  unreachable during onboarding so the provider is still listed for the user.

  Unlike `provision_with_key/2`, this does **not** wire the LLM/embedding/image
  configs and does **not** overwrite an existing credential. A later successful
  portal claim updates the same credential by name and fills in the API key.
  """
  @spec ensure_offline_credential() :: {:ok, AIProviderCredential.t()} | {:error, term()}
  def ensure_offline_credential do
    case System.get_ai_provider_credential_by_name(@credential_name) do
      nil -> System.create_ai_provider_credential(credential_attrs(%{}))
      %AIProviderCredential{} = existing -> {:ok, existing}
    end
  end

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

  defp client, do: Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)

  defp credential_attrs(extra) do
    Map.merge(
      %{
        name: @credential_name,
        provider: "zaq_router",
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
      |> LLMConfig.changeset(%{credential_id: cred_id, model: "openai/gpt-oss-120b"})
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
        model: "nvidia/nemotron-nano-12b-v2-vl"
      })
      |> System.save_image_to_text_config()
    end

    :ok
  end
end
