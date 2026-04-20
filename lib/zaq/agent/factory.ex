defmodule Zaq.Agent.Factory do
  @moduledoc """
  Standard Jido agent used for BO-managed configured agents.

  All configured agents execute through this module. Per-agent specifics are
  applied at runtime (server model state, set_system_prompt signal, request
  tool/llm options).
  """

  use Jido.AI.Agent,
    name: "agent_factory",
    description: "Runtime-configured standard ZAQ agent",
    request_policy: :reject,
    tools: []

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Registry
  alias Zaq.System

  def strategy_opts do
    super()
    |> Keyword.delete(:model)
  end

  @spec configure_server(GenServer.server(), ConfiguredAgent.t()) :: :ok | {:error, term()}
  def configure_server(server, %ConfiguredAgent{} = configured_agent) do
    case Jido.AI.set_system_prompt(server, configured_agent.job, timeout: 5_000) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ask_with_config(GenServer.server(), String.t(), ConfiguredAgent.t(), keyword()) ::
          {:ok, Jido.AI.Request.Handle.t()} | {:error, term()}
  def ask_with_config(server, query, %ConfiguredAgent{} = configured_agent, opts \\ [])
      when is_binary(query) do
    with {:ok, tools} <- Registry.resolve_modules(configured_agent.enabled_tool_keys || []) do
      ask_opts =
        opts
        |> Keyword.put(:tools, tools)
        |> Keyword.put(:llm_opts, llm_opts(configured_agent))
        |> Keyword.put_new(:timeout, 30_000)

      ask(server, query, ask_opts)
    end
  end

  defp llm_opts(%ConfiguredAgent{} = configured_agent) do
    credential = credential(configured_agent)

    configured_agent
    |> advanced_options_as_keyword()
    |> maybe_put(:api_key, credential && credential.api_key)
    |> maybe_put(:base_url, credential && credential.endpoint)
  end

  defp advanced_options_as_keyword(%ConfiguredAgent{advanced_options: options})
       when is_map(options) do
    options
    |> Enum.reduce([], fn {key, value}, acc ->
      case normalize_option_key(key) do
        nil -> acc
        atom_key -> [{atom_key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp advanced_options_as_keyword(_), do: []

  defp credential(%ConfiguredAgent{credential: credential}) when not is_nil(credential),
    do: credential

  defp credential(%ConfiguredAgent{credential_id: credential_id})
       when is_integer(credential_id) do
    System.get_ai_provider_credential(credential_id)
  end

  defp credential(_), do: nil

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_option_key(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
