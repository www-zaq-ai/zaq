defmodule Zaq.Agent do
  @moduledoc "Context for BO-managed custom agents."

  import Ecto.Query

  alias Ecto.Changeset
  alias Zaq.Agent.{ConfiguredAgent, MCP, QueryFilters, ServerManager}
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.Utils.ParseUtils

  @spec list_agents() :: [ConfiguredAgent.t()]
  def list_agents do
    ConfiguredAgent
    |> order_by([a], asc: a.name)
    |> preload(:credential)
    |> Repo.all()
  end

  @spec list_active_agents() :: [ConfiguredAgent.t()]
  def list_active_agents do
    ConfiguredAgent
    |> where([a], a.active == true)
    |> order_by([a], asc: a.name)
    |> preload(:credential)
    |> Repo.all()
  end

  @spec list_conversation_enabled_agents() :: [ConfiguredAgent.t()]
  def list_conversation_enabled_agents do
    ConfiguredAgent
    |> where([a], a.active == true and a.conversation_enabled == true)
    |> order_by([a], asc: a.name)
    |> preload(:credential)
    |> Repo.all()
  end

  @spec list_agents_with_mcp_endpoint(integer()) :: [ConfiguredAgent.t()]
  def list_agents_with_mcp_endpoint(endpoint_id) when is_integer(endpoint_id) do
    list_agents()
    |> Enum.filter(fn %ConfiguredAgent{} = agent ->
      endpoint_id in (agent.enabled_mcp_endpoint_ids || [])
    end)
  end

  @spec filter_agents(map(), keyword()) :: {[ConfiguredAgent.t()], non_neg_integer()}
  def filter_agents(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    base = build_filter_query(filters)
    total = Repo.aggregate(base, :count)

    agents =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> preload(:credential)
      |> Repo.all()

    {agents, total}
  end

  @spec get_agent!(integer() | String.t()) :: ConfiguredAgent.t()
  def get_agent!(id), do: id |> parse_id!() |> do_get_agent!()

  @spec get_agent(integer() | String.t()) :: ConfiguredAgent.t() | nil
  def get_agent(id) do
    with {:ok, int_id} <- ParseUtils.parse_int_strict(id) do
      ConfiguredAgent
      |> preload(:credential)
      |> Repo.get(int_id)
    end
  end

  @spec get_active_agent(integer() | String.t()) :: {:ok, ConfiguredAgent.t()} | {:error, atom()}
  def get_active_agent(id) do
    case get_agent(id) do
      %ConfiguredAgent{active: true} = agent -> {:ok, agent}
      %ConfiguredAgent{} -> {:error, :inactive_agent}
      nil -> {:error, :agent_not_found}
    end
  end

  @doc """
  Returns an agent eligible for conversation-channel routing.

  Eligibility requires both `active == true` and `conversation_enabled == true`.
  """
  @spec get_conversation_enabled_agent(integer() | String.t()) ::
          {:ok, ConfiguredAgent.t()} | {:error, atom()}
  def get_conversation_enabled_agent(id) do
    case get_agent(id) do
      %ConfiguredAgent{active: true, conversation_enabled: true} = agent -> {:ok, agent}
      %ConfiguredAgent{active: false} -> {:error, :inactive_agent}
      %ConfiguredAgent{conversation_enabled: false} -> {:error, :conversation_disabled}
      nil -> {:error, :agent_not_found}
    end
  end

  @spec create_agent(map()) :: {:ok, ConfiguredAgent.t()} | {:error, Changeset.t()}
  def create_agent(attrs) do
    %ConfiguredAgent{}
    |> ConfiguredAgent.changeset(attrs)
    |> apply_runtime_validations()
    |> Repo.insert()
    |> preload_credential()
  end

  @spec update_agent(ConfiguredAgent.t(), map()) ::
          {:ok, ConfiguredAgent.t()} | {:error, Changeset.t()}
  def update_agent(%ConfiguredAgent{} = agent, attrs) do
    agent
    |> ConfiguredAgent.changeset(attrs)
    |> apply_runtime_validations()
    |> Repo.update()
    |> preload_credential()
  end

  @spec delete_agent(ConfiguredAgent.t()) :: {:ok, ConfiguredAgent.t()} | {:error, Changeset.t()}
  def delete_agent(%ConfiguredAgent{} = agent) do
    usage_locations = usage_locations_for_agent(agent.id)

    if usage_locations == [] do
      # Stop runtime first so a successful row delete cannot leave an orphaned
      # long-lived agent server behind if the node crashes before cleanup.
      # A concurrent admin update can still reference the agent after this check;
      # in that case the BO delete can be retried safely.
      _ = ServerManager.stop_server(agent)

      case usage_locations_for_agent(agent.id) do
        [] ->
          Repo.delete(agent)

        late_usage_locations ->
          {:error, in_use_changeset(agent, late_usage_locations)}
      end
    else
      {:error, in_use_changeset(agent, usage_locations)}
    end
  end

  @spec change_agent(ConfiguredAgent.t(), map()) :: Changeset.t()
  def change_agent(%ConfiguredAgent{} = agent, attrs \\ %{}) do
    agent
    |> ConfiguredAgent.changeset(attrs)
    |> apply_runtime_validations()
  end

  @spec provider_for_agent(ConfiguredAgent.t()) :: String.t() | nil
  def provider_for_agent(%ConfiguredAgent{credential: %{provider: provider}})
      when is_binary(provider), do: provider

  def provider_for_agent(%ConfiguredAgent{credential_id: credential_id})
      when is_integer(credential_id) do
    case System.get_ai_provider_credential(credential_id) do
      %{provider: provider} when is_binary(provider) -> provider
      _ -> nil
    end
  end

  def provider_for_agent(_), do: nil

  @spec runtime_provider_for_agent(ConfiguredAgent.t()) :: {:ok, atom()} | {:error, atom()}
  def runtime_provider_for_agent(%ConfiguredAgent{} = configured_agent) do
    configured_agent
    |> provider_for_agent()
    |> runtime_provider_from_id()
  end

  @spec agent_server_id(integer() | String.t()) :: String.t()
  def agent_server_id(agent_id), do: "configured_agent_#{agent_id}"

  defp do_get_agent!(id) do
    ConfiguredAgent
    |> preload(:credential)
    |> Repo.get!(id)
  end

  defp preload_credential({:ok, %ConfiguredAgent{} = agent}),
    do: {:ok, Repo.preload(agent, :credential)}

  defp preload_credential(other), do: other

  defp apply_runtime_validations(%Changeset{} = changeset) do
    provider = provider_from_changeset(changeset)

    changeset
    |> validate_runtime_provider(provider)
    |> validate_tool_capability(provider)
    |> validate_mcp_endpoint_assignments()
  end

  defp validate_mcp_endpoint_assignments(%Changeset{} = changeset) do
    ids = Changeset.get_field(changeset, :enabled_mcp_endpoint_ids) || []

    unknown_ids =
      ids
      |> Enum.uniq()
      |> Enum.reject(fn endpoint_id ->
        match?(%MCP.Endpoint{}, MCP.get_mcp_endpoint(endpoint_id))
      end)

    if unknown_ids == [] do
      changeset
    else
      Changeset.add_error(
        changeset,
        :enabled_mcp_endpoint_ids,
        "contains unknown MCP endpoint ids: #{Enum.join(unknown_ids, ", ")}"
      )
    end
  end

  defp validate_tool_capability(%Changeset{} = changeset, provider) do
    keys = Changeset.get_field(changeset, :enabled_tool_keys) || []

    if keys == [] do
      changeset
    else
      credential_id = Changeset.get_field(changeset, :credential_id)
      model = Changeset.get_field(changeset, :model)
      provider_id = provider || provider_from_credential_id(credential_id)

      case Registry.model_supports_tools?(provider_id, model) do
        false ->
          Changeset.add_error(
            changeset,
            :enabled_tool_keys,
            "selected model does not support tool calling"
          )

        _ ->
          changeset
      end
    end
  end

  defp validate_runtime_provider(%Changeset{} = changeset, provider) do
    case provider do
      nil ->
        changeset

      provider_id ->
        case runtime_provider_from_id(provider_id) do
          {:ok, _provider} ->
            changeset

          {:error, reason} ->
            Changeset.add_error(
              changeset,
              :credential_id,
              "selected provider cannot be used at runtime (#{reason})"
            )
        end
    end
  end

  defp provider_from_changeset(%Changeset{} = changeset) do
    credential_id = Changeset.get_field(changeset, :credential_id)

    case changeset.data do
      %ConfiguredAgent{
        credential_id: ^credential_id,
        credential: %AIProviderCredential{provider: provider}
      }
      when is_binary(provider) ->
        provider

      _ ->
        provider_from_credential_id(credential_id)
    end
  end

  defp provider_from_credential_id(nil), do: nil

  defp provider_from_credential_id(credential_id) do
    case System.get_ai_provider_credential(credential_id) do
      %{provider: provider} when is_binary(provider) -> provider
      _ -> nil
    end
  end

  defp runtime_provider_from_id(provider_id) when is_binary(provider_id) do
    with {:ok, provider_atom} <- to_existing_atom(provider_id) do
      runtime_provider_from_atom(provider_atom)
    end
  end

  defp runtime_provider_from_id(_), do: {:error, :invalid_provider}

  defp usage_locations_for_agent(agent_id) do
    retrieval_channel_usages(agent_id) ++
      provider_default_usages(agent_id) ++
      imap_mailbox_usages(agent_id) ++
      global_default_usage(agent_id)
  end

  defp retrieval_channel_usages(agent_id) do
    RetrievalChannel
    |> join(:inner, [r], c in ChannelConfig, on: r.channel_config_id == c.id)
    |> where([r], r.configured_agent_id == ^agent_id)
    |> select([r, c], {c.provider, r.channel_name, r.channel_id})
    |> Repo.all()
    |> Enum.map(fn {provider, channel_name, channel_id} ->
      "retrieval channel #{provider}:#{channel_name || channel_id}"
    end)
  end

  defp provider_default_usages(agent_id) do
    ChannelConfig
    |> where(
      [config],
      fragment("?->'routing'->>'default_agent_id' = ?", config.settings, ^to_string(agent_id))
    )
    |> select([config], config.provider)
    |> Repo.all()
    |> Enum.map(&"provider default #{&1}")
  end

  defp imap_mailbox_usages(agent_id) do
    imap_mailbox_assignments()
    |> imap_mailbox_usages_for_agent(agent_id)
  end

  defp imap_mailbox_assignments do
    case ChannelConfig.get_any_by_provider("email:imap") do
      %{settings: settings} when is_map(settings) ->
        case get_in(settings, ["imap", "agent_routing", "mailboxes"]) do
          mailboxes when is_map(mailboxes) -> mailboxes
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp imap_mailbox_usages_for_agent(mailboxes, agent_id) when is_map(mailboxes) do
    mailboxes
    |> Enum.filter(fn {_mailbox, assigned_id} ->
      ParseUtils.parse_optional_int(assigned_id) == agent_id
    end)
    |> Enum.map(fn {mailbox, _assigned_id} -> "imap mailbox #{mailbox}" end)
  end

  defp global_default_usage(agent_id) do
    if System.get_global_default_agent_id() == agent_id do
      ["global default channels.global_default_agent_id"]
    else
      []
    end
  end

  defp in_use_changeset(%ConfiguredAgent{} = agent, usage_locations) do
    message =
      usage_locations
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("\n", &"- #{&1}")
      |> then(&"Agent is in use by:\n#{&1}")

    agent
    |> Changeset.change()
    |> Changeset.add_error(:base, message)
  end

  defp runtime_provider_from_atom(provider_atom) when is_atom(provider_atom) do
    case ReqLLM.provider(provider_atom) do
      {:ok, _provider_module} ->
        {:ok, provider_atom}

      {:error, _} ->
        case LLMDB.provider(provider_atom) do
          {:ok, %LLMDB.Provider{catalog_only: true}} -> {:ok, :openai}
          {:ok, _provider} -> {:error, :provider_not_supported}
          _ -> {:error, :provider_not_found}
        end
    end
  end

  @doc false
  @spec to_existing_atom(String.t()) :: {:ok, atom()} | {:error, :provider_not_found}
  # Provider ids come from DB/user-configured credentials. We only convert values
  # that already exist as loaded atoms to avoid atom leaks. Unknown values return
  # {:error, :provider_not_found}.
  defp to_existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :provider_not_found}
  end

  defp build_filter_query(filters) do
    name = Map.get(filters, "name", "")
    model = Map.get(filters, "model", "")
    conversation = Map.get(filters, "conversation_enabled", "all")
    active = Map.get(filters, "active", "all")
    sovereign = Map.get(filters, "sovereign", "all")

    ConfiguredAgent
    |> order_by([a], asc: a.name)
    |> QueryFilters.maybe_filter_ilike(name, :name)
    |> maybe_filter_model(model)
    |> maybe_filter_conversation(conversation)
    |> maybe_filter_active(active)
    |> maybe_filter_sovereign(sovereign)
  end

  defp maybe_filter_model(query, ""), do: query

  defp maybe_filter_model(query, model) do
    escaped = String.replace(model, "%", "\\%")
    from(a in query, where: ilike(a.model, ^"%#{escaped}%"))
  end

  defp maybe_filter_conversation(query, "enabled"),
    do: from(a in query, where: a.conversation_enabled == true)

  defp maybe_filter_conversation(query, "disabled"),
    do: from(a in query, where: a.conversation_enabled == false)

  defp maybe_filter_conversation(query, _), do: query

  defp maybe_filter_active(query, "active"), do: from(a in query, where: a.active == true)
  defp maybe_filter_active(query, "inactive"), do: from(a in query, where: a.active == false)
  defp maybe_filter_active(query, _), do: query

  defp maybe_filter_sovereign(query, "sovereign") do
    from(a in query,
      join: c in assoc(a, :credential),
      where: c.sovereign == true
    )
  end

  defp maybe_filter_sovereign(query, "non_sovereign") do
    from(a in query,
      join: c in assoc(a, :credential),
      where: c.sovereign == false
    )
  end

  defp maybe_filter_sovereign(query, _), do: query

  defp parse_id!(id) do
    case ParseUtils.parse_int_strict(id) do
      {:ok, int} -> int
      :error -> raise ArgumentError, "invalid id: #{inspect(id)}"
    end
  end
end
