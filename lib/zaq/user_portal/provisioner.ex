defmodule Zaq.UserPortal.Provisioner do
  @moduledoc """
  Provisions the ZAQ Router credential from user portal onboarding results.

  This module owns the portal-specific bootstrap behavior: creating or updating
  the "ZAQ Router" credential, and wiring first-run model configs when the
  portal returns a LiteLLM API key. It delegates all persistence to `Zaq.System`.
  """

  alias Zaq.Accounts.User
  alias Zaq.Agent.ZAQProvider
  alias Zaq.Repo
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
  Provisions the portal account for an already-onboarded user.

  Used from the dashboard retry flow when the admin previously declined portal
  consent during bootstrap. On success, marks the user's portal consent as
  accepted and provisions the LiteLLM credential.
  """
  @spec provision_for_existing_user(User.t()) :: {:ok, User.t()} | {:error, term()}
  def provision_for_existing_user(%User{} = user) do
    case provision_for_user(user.email) do
      {:ok, _credential} ->
        user
        |> User.portal_consent_changeset("accepted")
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
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
        model: "google/gemma-4-31b-it"
      })
      |> System.save_image_to_text_config()
    end

    :ok
  end
end
