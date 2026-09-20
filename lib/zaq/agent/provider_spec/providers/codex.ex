defmodule Zaq.Agent.ProviderSpec.Providers.Codex do
  @moduledoc "OpenAI Codex ReqLLM runtime translation."

  @behaviour Zaq.Agent.ProviderSpec.Behaviour

  alias Zaq.Utils.Map, as: MapUtils

  @default_base_url "https://chatgpt.com/backend-api"

  @impl true
  def reqllm_provider(_provider), do: :openai_codex

  @impl true
  def fixed_url_provider?(_provider), do: false

  @impl true
  def put_model_spec(spec, context) do
    case context.endpoint do
      endpoint when is_binary(endpoint) and endpoint != "" -> Map.put(spec, :base_url, endpoint)
      _ -> spec
    end
  end

  @impl true
  def put_credential_opts(opts, context) do
    token = context.authentication[:access_token] || context.authentication[:api_key]
    provider_options = provider_options(opts, context)

    opts
    |> Keyword.drop([:api_key, :access_token, :auth_mode, :base_url, :provider_options])
    |> put_present(:access_token, token)
    |> Keyword.put(:auth_mode, :oauth)
    |> Keyword.put(:base_url, runtime_base_url(context.metadata))
    |> Keyword.put(:provider_options, provider_options)
  end

  @impl true
  def default_advanced_options(_config), do: %{}

  defp provider_options(opts, context) do
    provider_options =
      case Keyword.get(opts, :provider_options, []) do
        options when is_list(options) -> options
        _ -> []
      end

    provider_options =
      provider_options
      |> Keyword.drop([:auth_mode, :codex_originator, :chatgpt_account_id])
      |> Keyword.put(:auth_mode, :oauth)

    provider_options =
      put_present(provider_options, :codex_originator, originator(context.metadata))

    put_present(
      provider_options,
      :chatgpt_account_id,
      MapUtils.metadata_value(context.runtime_identity, "chatgpt_account_id")
    )
  end

  defp put_present(opts, _key, value) when value in [nil, ""], do: opts
  defp put_present(opts, key, value) when is_binary(value), do: Keyword.put(opts, key, value)

  defp originator(metadata) do
    metadata
    |> MapUtils.metadata_value("authorize_params")
    |> case do
      %{} = params -> MapUtils.metadata_value(params, "originator")
      _ -> nil
    end
  end

  defp runtime_base_url(metadata),
    do: MapUtils.metadata_value(metadata, "backend_base_url") || @default_base_url
end
