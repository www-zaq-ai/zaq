defmodule Zaq.Agent.ProviderSpec.Providers.Default do
  @moduledoc "Generic ReqLLM translation for native and OpenAI-compatible providers."

  @behaviour Zaq.Agent.ProviderSpec.Behaviour

  @fixed_url_providers ~w(anthropic google xai mistral)a

  @impl true
  def reqllm_provider(provider) do
    with {:ok, atom} <- provider_atom(provider),
         {:ok, _provider_module} <- ReqLLM.provider(atom) do
      atom
    else
      _ -> provider_from_llmdb(provider)
    end
  end

  @impl true
  def fixed_url_provider?(provider) when is_atom(provider),
    do: provider in @fixed_url_providers

  def fixed_url_provider?(provider) when is_binary(provider) do
    fixed_url_provider?(String.to_existing_atom(provider))
  rescue
    ArgumentError -> false
  end

  def fixed_url_provider?(_provider), do: false

  @impl true
  def put_model_spec(spec, context) do
    if fixed_url_provider?(context.runtime_provider) do
      spec
    else
      case context.endpoint do
        endpoint when is_binary(endpoint) and endpoint != "" ->
          Map.put(spec, :base_url, endpoint)

        _ ->
          spec
      end
    end
  end

  @impl true
  def put_credential_opts(opts, context) do
    secret =
      context.authentication[:api_key] || context.authentication[:access_token]

    opts =
      if context.auth_kind == "none" do
        Keyword.drop(opts, [:api_key, :access_token, :auth_mode])
      else
        opts = Keyword.delete(opts, :access_token)

        if secret in [nil, ""],
          do: Keyword.delete(opts, :api_key),
          else: Keyword.put(opts, :api_key, secret)
      end

    case context.endpoint do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        Keyword.put(opts, :base_url, endpoint)

      _ ->
        opts
    end
  end

  @impl true
  def default_advanced_options(%{supports_logprobs: true} = config) do
    if reqllm_provider(config.provider) == :openai,
      do: %{provider_options: [openai_logprobs: true]},
      else: %{}
  end

  def default_advanced_options(_config), do: %{}

  defp provider_from_llmdb(provider) do
    with {:ok, atom} <- LLMDB.Spec.parse_provider(provider),
         {:ok, %LLMDB.Provider{catalog_only: false}} <- LLMDB.provider(atom),
         {:ok, _provider_module} <- ReqLLM.provider(atom) do
      atom
    else
      _ -> :openai
    end
  end

  defp provider_atom(provider) when is_atom(provider), do: {:ok, provider}

  defp provider_atom(provider) when is_binary(provider) do
    {:ok, String.to_existing_atom(provider)}
  rescue
    ArgumentError -> :error
  end

  defp provider_atom(_provider), do: :error
end
