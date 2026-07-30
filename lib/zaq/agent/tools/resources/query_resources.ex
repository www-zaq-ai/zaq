defmodule Zaq.Agent.Tools.Resources.QueryResources do
  @moduledoc """
  Queries allowlisted Ecto resources for agents and workflows.

  Resource names are intentionally limited to: `agent`, `mcp`, `skill`, `user`,
  `person`, `ai_provider`, `channel_config`, and `incoming_message_routing_rule`. Data source connector configs are `channel_config` resources with `kind: "data_source"`. Use `mode: "describe"` to discover each resource's
  output fields, search fields, filter fields, sort fields, and public/private
  access policy. Use `mode: "query"` to get one resource by id or list/search
  resources with filters and pagination.
  """

  @resource_names ~w(agent mcp skill user person ai_provider channel_config incoming_message_routing_rule)

  @schema Zoi.object(%{
            mode:
              Zoi.enum(["describe", "query"],
                description:
                  "Use describe to discover fields, or query to get/list/search resources. Defaults to query."
              )
              |> Zoi.default("query"),
            resource_type:
              Zoi.enum(@resource_names,
                description:
                  "Resource type. Allowed: agent, mcp, skill, user, person, ai_provider, channel_config, incoming_message_routing_rule. Use channel_config with filter kind=data_source for data source connector configs. Optional only for mode=describe."
              )
              |> Zoi.optional(),
            id:
              Zoi.union([Zoi.string(), Zoi.integer()],
                description: "Optional resource id. When present, the tool runs in get mode."
              )
              |> Zoi.optional(),
            query:
              Zoi.string(
                description:
                  "Optional free-text search across the resource's search_fields. Use mode=describe to inspect them."
              )
              |> Zoi.optional(),
            filters:
              Zoi.map(Zoi.string(), Zoi.any(),
                description:
                  "Optional exact filters. Keys must be listed in the resource's filter_fields."
              )
              |> Zoi.default(%{}),
            fields:
              Zoi.list(Zoi.string(),
                description:
                  "Optional output fields. Values must be listed in the resource's fields."
              )
              |> Zoi.default([]),
            sort_by:
              Zoi.string(description: "Optional sort field listed in the resource's sort_fields.")
              |> Zoi.optional(),
            sort_dir:
              Zoi.enum(["asc", "desc"], description: "Sort direction. Defaults to asc.")
              |> Zoi.default("asc"),
            limit:
              Zoi.integer(
                description: "Maximum rows to return. Defaults to 20 and is capped per resource."
              )
              |> Zoi.default(20),
            offset:
              Zoi.integer(description: "Zero-based pagination offset. Defaults to 0.")
              |> Zoi.default(0)
          })

  @resource_descriptor_schema Zoi.object(%{
                                resource_type: Zoi.string(),
                                public: Zoi.boolean(),
                                fields: Zoi.list(Zoi.string()),
                                search_fields: Zoi.list(Zoi.string()),
                                filter_fields: Zoi.list(Zoi.string()),
                                sort_fields: Zoi.list(Zoi.string()),
                                default_sort: Zoi.string(),
                                max_limit: Zoi.integer()
                              })

  @output_schema Zoi.object(%{
                   mode: Zoi.string(description: "describe, get, or query."),
                   resource_type: Zoi.string() |> Zoi.nullable(),
                   resources: Zoi.list(Zoi.map()),
                   resource: Zoi.map() |> Zoi.nullable(),
                   found: Zoi.boolean(),
                   count: Zoi.integer(),
                   total_count: Zoi.integer(),
                   limit: Zoi.integer(),
                   offset: Zoi.integer(),
                   descriptions: Zoi.list(@resource_descriptor_schema)
                 })

  use Zaq.Engine.Workflows.Action,
    name: "query_resources",
    description:
      "Query allowlisted ZAQ Ecto resources: agent, mcp, skill, user, person, ai_provider, channel_config, incoming_message_routing_rule. Data source connector configs are channel_config rows with kind=data_source. Use mode=describe to discover fields/search_fields/filter_fields/sort_fields. Use mode=query with optional id for get mode, or query/filters/sort/limit/offset for list/search mode. Public reads: agent, mcp, skill. Private reads require permissions or skip_permissions.",
    schema: @schema,
    output_schema: @output_schema

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.Resources.Query
  alias Zaq.Agent.Tools.Resources.Registry

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{mode: "describe", resource_type: resource_type}, _context)
      when is_binary(resource_type) do
    with {:ok, descriptor} <- Registry.get(resource_type) do
      {:ok, describe_response(resource_type, [Registry.describe(descriptor)])}
    end
  end

  def run(%{mode: "describe"}, _context) do
    {:ok, describe_response(nil, Registry.describe_all())}
  end

  def run(%{mode: "query", resource_type: resource_type} = params, context)
      when is_binary(resource_type) do
    with {:ok, descriptor} <- Registry.get(resource_type) do
      Query.run(descriptor, params, context)
    end
  end

  def run(%{mode: "query"}, _context), do: {:error, :resource_type_required}

  defp describe_response(resource_type, descriptions) do
    %{
      mode: "describe",
      resource_type: resource_type,
      descriptions: descriptions,
      resources: [],
      resource: nil,
      found: descriptions != [],
      count: length(descriptions),
      total_count: length(descriptions),
      limit: length(descriptions),
      offset: 0
    }
  end
end
