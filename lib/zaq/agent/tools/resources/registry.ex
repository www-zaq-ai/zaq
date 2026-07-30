defmodule Zaq.Agent.Tools.Resources.Registry do
  @moduledoc """
  Allowlist of Ecto resources exposed through the `resources.query` tool.

  This registry is the security boundary for dynamic resource access: tool input
  names resource keys, never modules or table names, and every searchable,
  filterable, sortable, and serializable field is declared here explicitly.
  """

  @type descriptor :: %{
          required(:key) => String.t(),
          required(:module) => module(),
          required(:public?) => boolean(),
          required(:fields) => [atom()],
          required(:search_fields) => [atom()],
          required(:filter_fields) => [atom()],
          required(:sort_fields) => [atom()],
          required(:default_sort) => atom(),
          required(:max_limit) => pos_integer()
        }

  @resources [
    %{
      key: "agent",
      module: Zaq.Agent.ConfiguredAgent,
      public?: true,
      fields:
        ~w(id name description job model enabled_tool_keys enabled_mcp_endpoint_ids enabled_skill_ids conversation_enabled strategy active inserted_at updated_at)a,
      search_fields: ~w(name description job model)a,
      filter_fields: ~w(active conversation_enabled strategy model credential_id)a,
      sort_fields: ~w(id name model active inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "mcp",
      module: Zaq.Agent.MCP.Endpoint,
      public?: true,
      fields: ~w(id name type status timeout_ms predefined_id inserted_at updated_at)a,
      search_fields: ~w(name type status predefined_id)a,
      filter_fields: ~w(type status predefined_id)a,
      sort_fields: ~w(id name type status inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "skill",
      module: Zaq.Agent.Skill,
      public?: true,
      fields:
        ~w(id name description provided_tool_keys allowed_tools enabled_mcp_endpoint_ids resource_root tags active inserted_at updated_at)a,
      search_fields: ~w(name description tags)a,
      filter_fields: ~w(active provided_tool_keys allowed_tools enabled_mcp_endpoint_ids tags)a,
      sort_fields: ~w(id name active inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "user",
      module: Zaq.Accounts.User,
      public?: false,
      fields:
        ~w(id username email role_id must_change_password portal_consent inserted_at updated_at)a,
      search_fields: ~w(username email portal_consent)a,
      filter_fields: ~w(role_id must_change_password portal_consent)a,
      sort_fields: ~w(id username email inserted_at updated_at)a,
      default_sort: :username,
      max_limit: 100
    },
    %{
      key: "person",
      module: Zaq.Accounts.Person,
      public?: false,
      fields:
        ~w(id full_name email phone role status incomplete team_ids channels inserted_at updated_at)a,
      search_fields: ~w(full_name email phone role status)a,
      filter_fields: ~w(status role incomplete team_ids)a,
      sort_fields: ~w(id full_name email status inserted_at updated_at)a,
      default_sort: :full_name,
      max_limit: 100
    },
    %{
      key: "ai_provider",
      module: Zaq.System.AIProviderCredential,
      public?: false,
      fields: ~w(id name provider endpoint sovereign description inserted_at updated_at)a,
      search_fields: ~w(name provider endpoint description)a,
      filter_fields: ~w(provider sovereign)a,
      sort_fields: ~w(id name provider sovereign inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "channel_config",
      module: Zaq.Channels.ChannelConfig,
      public?: false,
      fields: ~w(id name provider kind url enabled retrieval_channels inserted_at updated_at)a,
      search_fields: ~w(name provider kind url retrieval_channels)a,
      filter_fields: ~w(provider kind enabled)a,
      sort_fields: ~w(id name provider kind enabled inserted_at updated_at)a,
      default_sort: :name,
      max_limit: 100
    },
    %{
      key: "incoming_message_routing_rule",
      module: Zaq.Engine.IncomingMessageRoutingRule,
      public?: false,
      fields:
        ~w(id person_id channel_config_id retrieval_channel_id configured_agent_id topic_id routing_mode inserted_at updated_at)a,
      search_fields: ~w(person_id channel_config_id topic_id routing_mode)a,
      filter_fields:
        ~w(person_id channel_config_id retrieval_channel_id configured_agent_id topic_id routing_mode)a,
      sort_fields: ~w(id inserted_at updated_at)a,
      default_sort: :id,
      max_limit: 100
    }
  ]

  @spec all() :: [descriptor()]
  def all, do: @resources

  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@resources, & &1.key)

  @spec get(String.t()) :: {:ok, descriptor()} | {:error, {:unknown_resource_type, String.t()}}
  def get(key) when is_binary(key) do
    case Enum.find(@resources, &(&1.key == key)) do
      nil -> {:error, {:unknown_resource_type, key}}
      descriptor -> {:ok, descriptor}
    end
  end

  def get(key), do: {:error, {:unknown_resource_type, inspect(key)}}

  @spec describe_all() :: [map()]
  def describe_all, do: Enum.map(@resources, &describe/1)

  @spec describe(descriptor()) :: map()
  def describe(descriptor) do
    %{
      resource_type: descriptor.key,
      public: descriptor.public?,
      fields: stringify(descriptor.fields),
      search_fields: stringify(descriptor.search_fields),
      filter_fields: stringify(descriptor.filter_fields),
      sort_fields: stringify(descriptor.sort_fields),
      default_sort: to_string(descriptor.default_sort),
      max_limit: descriptor.max_limit
    }
  end

  defp stringify(fields), do: Enum.map(fields, &to_string/1)
end
