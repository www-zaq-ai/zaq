defmodule Zaq.UserPortal.Provisioner do
  @moduledoc """
  Provisions the ZAQ Router credential from user portal onboarding results.

  This module owns the portal-specific bootstrap behavior: creating or updating
  the "ZAQ Router" credential, and wiring first-run model configs when the
  portal returns a LiteLLM API key. It delegates all persistence to `Zaq.System`.
  """

  alias Zaq.Agent.ZAQRouter
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig

  require Logger

  @credential_name "ZAQ Router"
  @description "ZAQ Router gives you the ability to access different models."

  @doc "The canonical name of the ZAQ Router credential."
  @spec credential_name() :: String.t()
  def credential_name, do: @credential_name

  @doc """
  Calls the portal to onboard the user by email and provisions the ZAQ credential
  with the returned API key. Returns `{:ok, credential}` or `{:error, reason}`.
  """
  @spec provision_for_user(String.t()) :: {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_for_user(email) when is_binary(email) do
    case Zaq.UserPortal.client().onboard_user(email) do
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

  @spec provision_with_key(%{litellm_api_key: String.t()}) ::
          {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_with_key(%{litellm_api_key: api_key}) when is_binary(api_key) do
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

  defp credential_attrs(extra) do
    Map.merge(
      %{
        name: @credential_name,
        provider: "zaq_router",
        endpoint: ZAQRouter.default_endpoint(),
        sovereign: false,
        description: @description
      },
      extra
    )
  end

  defp provision_system_configs(%AIProviderCredential{id: cred_id}) do
    {embedding_model, embedding_dimension} = ZAQRouter.default_embedding_model()

    if is_nil(System.get_llm_config().credential_id) do
      %LLMConfig{}
      |> LLMConfig.changeset(%{credential_id: cred_id, model: ZAQRouter.default_chat_model()})
      |> System.save_llm_config()
      |> log_config_result("LLM")
    end

    if is_nil(System.get_embedding_config().credential_id) do
      %EmbeddingConfig{}
      |> EmbeddingConfig.changeset(%{
        credential_id: cred_id,
        model: embedding_model,
        dimension: embedding_dimension
      })
      |> System.save_embedding_config()
      |> log_config_result("embedding")
    end

    if is_nil(System.get_image_to_text_config().credential_id) do
      %ImageToTextConfig{}
      |> ImageToTextConfig.changeset(%{
        credential_id: cred_id,
        model: ZAQRouter.default_image_model()
      })
      |> System.save_image_to_text_config()
      |> log_config_result("image-to-text")
    end

    :ok
  end

  # Config wiring is best-effort — a failure here must not roll back the
  # already-created credential — but it must never fail silently.
  defp log_config_result({:ok, _config} = result, _label), do: result

  defp log_config_result({:error, reason} = result, label) do
    Logger.warning("ZAQ Router #{label} config wiring failed: #{inspect(reason)}")
    result
  end
end
