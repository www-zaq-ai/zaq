defmodule Zaq.UserPortal.Provisioner do
  @moduledoc """
  Provisions the ZAQ Router credential from user portal onboarding results.

  This module owns the portal-specific bootstrap behavior: creating or updating
  the "ZAQ Router" credential, configured assistant and first-run model configs when the
  portal returns a LiteLLM API key. Credential and routing mutations are dispatched
  to Engine, and configured-agent operations to Agent; local System calls are
  limited to existing configuration reads/writes.
  """

  alias Zaq.Agent
  alias Zaq.Agent.ZAQRouter
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig

  require Logger

  @credential_name "ZAQ Router"
  @agent_name "ZAQ Assistant"
  @description "ZAQ Router gives you the ability to access different models."
  @engine_actor %{kind: :system, subject: "user-portal-provisioner"}

  @doc "The canonical name of the ZAQ Router credential."
  @spec credential_name() :: String.t()
  def credential_name, do: @credential_name

  @doc """
  Returns `true` when the ZAQ Router credential exists with a non-empty API key.

  Used to decide whether the portal activation banner is still needed: a user
  with a working key is fully provisioned, while a keyless (scaffolded) or absent
  credential means provisioning is still pending.
  """
  @spec router_key_set?() :: boolean()
  def router_key_set? do
    case System.get_ai_provider_credential_by_name(@credential_name) do
      %AIProviderCredential{} = credential ->
        System.resolve_ai_provider_api_key(credential) != ""

      _ ->
        false
    end
  end

  @doc """
  Claims a LiteLLM API key from the portal for `email` **without** writing
  anything locally. Returns `{:ok, %{litellm_api_key: key}}` or `{:error, reason}`.

  Pair with `provision_with_key/1` to persist the credential and bootstrap its
  configured agent after account registration has succeeded.
  """
  @spec claim_key(String.t()) :: {:ok, %{litellm_api_key: String.t()}} | {:error, term()}
  def claim_key(email) when is_binary(email) do
    Zaq.UserPortal.client().onboard_user(email)
  end

  @doc """
  Calls the portal to onboard the user by email and provisions the ZAQ credential
  with the returned API key. Returns `{:ok, credential}` or `{:error, reason}`.
  """
  @spec provision_for_user(String.t()) :: {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_for_user(email) when is_binary(email) do
    case claim_key(email) do
      {:ok, litellm} -> provision_with_key(litellm)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates the "ZAQ Router" credential with no API key, used when the portal is
  unreachable during onboarding so the provider is still listed for the user.

  Unlike `provision_with_key/1`, this does **not** create an agent or wire
  embedding/image configs and does **not** overwrite an existing credential. A later successful
  portal claim updates the same credential by name and fills in the API key.
  """
  @spec ensure_offline_credential(keyword()) ::
          {:ok, AIProviderCredential.t()} | {:error, term()}
  def ensure_offline_credential(opts \\ []) do
    case System.get_ai_provider_credential_by_name(@credential_name) do
      nil ->
        credential_attrs(%{auth_kind: "none"})
        |> create_credential(opts)

      %AIProviderCredential{} = existing ->
        {:ok, existing}
    end
  end

  @spec provision_with_key(%{litellm_api_key: String.t()}, keyword()) ::
          {:ok, AIProviderCredential.t()} | {:error, term()}
  def provision_with_key(%{litellm_api_key: api_key}, opts \\ []) when is_binary(api_key) do
    attrs = credential_attrs(%{api_key: api_key, auth_kind: "api_key"})

    result =
      case System.get_ai_provider_credential_by_name(@credential_name) do
        nil -> create_credential(attrs, opts)
        existing -> update_credential(existing, attrs, opts)
      end

    with {:ok, credential} <- result,
         {:ok, agent} <- provision_agent(credential, opts),
         {:ok, _routing} <- provision_global_routing(agent, opts) do
      provision_system_configs(credential)
      {:ok, credential}
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

  defp create_credential(attrs, opts) do
    dispatch_engine(
      %{attrs: attrs},
      :system_config_create_ai_provider_credential,
      opts
    )
  end

  defp update_credential(credential, attrs, opts) do
    dispatch_engine(
      %{credential: credential, attrs: attrs},
      :system_config_update_ai_provider_credential,
      opts
    )
  end

  defp dispatch_engine(request, action, opts) do
    dispatch(request, :engine, action, opts)
  end

  defp dispatch(request, destination, action, opts) do
    event =
      Event.new(request, destination,
        actor: @engine_actor,
        opts: [action: action, confidential: true]
      )

    opts
    |> Keyword.get(:node_router_module, NodeRouter)
    |> then(& &1.dispatch(event).response)
  end

  defp provision_agent(%AIProviderCredential{id: credential_id}, opts) do
    request = %{module: Agent, function: :get_agent_by_name, args: [@agent_name]}

    case dispatch(request, :agent, :invoke, opts) do
      {:error, :agent_not_found} ->
        attrs = %{
          name: @agent_name,
          job: "Help users answer questions using the company knowledge base.",
          credential_id: credential_id,
          model: ZAQRouter.default_chat_model(),
          conversation_enabled: true,
          enabled_tool_keys: [
            "answering.search_knowledge_base",
            "answering.get_knowledge_base_chunks"
          ]
        }

        dispatch(%{module: Agent, function: :create_agent, args: [attrs]}, :agent, :invoke, opts)

      result ->
        result
    end
  end

  defp provision_global_routing(agent, opts) do
    case IncomingMessageRouting.get_rule(%{}) do
      nil ->
        dispatch_engine(
          %{rules: [%{routing_mode: "agent", configured_agent_id: agent.id}]},
          :upsert_incoming_message_routing_rules,
          opts
        )

      rule ->
        {:ok, rule}
    end
  end

  defp provision_system_configs(%AIProviderCredential{id: cred_id}) do
    {embedding_model, embedding_dimension} = ZAQRouter.default_embedding_model()

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
