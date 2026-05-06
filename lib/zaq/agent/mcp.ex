defmodule Zaq.Agent.MCP do
  @moduledoc "Context for BO-managed MCP endpoint administration."

  import Ecto.Query

  alias Ecto.Changeset
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP.{Endpoint, Runtime}
  alias Zaq.Agent.QueryFilters
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString

  @secret_fields [:secret_headers, :secret_environments]

  @predefined %{
    # "filesystem" => %{
    #   id: "filesystem",
    #   name: "Filesystem",
    #   icon: "hero-folder",
    #   editable: false,
    #   defaults: %{
    #     type: "local",
    #     status: "disabled",
    #     timeout_ms: 5000,
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem"],
    #     environments: %{},
    #     secret_environments: %{},
    #     headers: %{},
    #     secret_headers: %{},
    #     settings: %{}
    #   }
    # },
    "github_mcp" => %{
      id: "github_mcp",
      name: "Github",
      icon: "hero-code-bracket-square",
      description: "Official GitHub MCP for repository operations, pull requests, and issues.",
      editable: true,
      defaults: %{
        type: "remote",
        status: "disabled",
        timeout_ms: 5000,
        url: "https://api.githubcopilot.com/mcp/",
        headers: %{},
        secret_headers: %{"Authorization" => "t"},
        environments: %{},
        secret_environments: %{},
        settings: %{}
      }
    },
    "stripe_mcp" => %{
      id: "stripe_mcp",
      name: "Stripe",
      icon: "hero-credit-card-solid",
      description: "Stripe MCP for payments, customers, and billing workflows.",
      editable: true,
      defaults: %{
        type: "remote",
        status: "disabled",
        timeout_ms: 5000,
        url: "https://mcp.stripe.com",
        headers: %{},
        secret_headers: %{"Authorization" => "Bearer {restricted api key}"},
        environments: %{},
        secret_environments: %{},
        settings: %{}
      }
    },
    # MCP Client incompatibility
    #  [debug] MCP transport details: %{timeout: 30000, url: "https://www.context-awesome.com/api/mcp", headers:
    # %{"accept" => "application/json, text/event-stream", "content-type" => "application/json"}, method: :post}
    # [error] MCP transport event: http_request_error
    # [error] MCP transport details: %{reason: "{:http_error, 406, \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"error\\\":{\\\
    # "code\\\":-32000,\\\"message\\\":\\\"Not Acceptable: Client must accept both application/json
    # and text/event-stream\\\"},\\\"id\\\":null}\"}"}
    # "context_awesome_mcp" => %{
    #   id: "context_awesome_mcp",
    #   name: "Context Awesome",
    #   icon: "hero-command-line",
    #   description:
    #     "Community-curated collections of the best tools, libraries, and resources on any topic.",
    #   editable: true,
    #   defaults: %{
    #     type: "remote",
    #     status: "enabled",
    #     timeout_ms: 5000,
    #     url: "https://www.context-awesome.com/api/mcp",
    #     headers: %{},
    #     secret_headers: %{},
    #     environments: %{},
    #     secret_environments: %{},
    #     settings: %{}
    #   }
    # },
    "datagouv_mcp" => %{
      id: "datagouv_mcp",
      name: "Datagouv MCP",
      icon: "hero-building-library-solid",
      description: "French public data MCP endpoint (data.gouv.fr) for open-data exploration.",
      editable: true,
      defaults: %{
        type: "remote",
        status: "enabled",
        timeout_ms: 10_000,
        url: "https://mcp.data.gouv.fr/mcp",
        headers: %{},
        secret_headers: %{},
        environments: %{},
        secret_environments: %{},
        settings: %{}
      }
    }
    # MCP Client incompatibility
    #     debug] MCP transport details: %{timeout: 30000, url: "https://mcp.tweetsave.org/sse", headers:
    # %{"accept" => "application/json, text/event-stream", "content-type" => "application/json"}, method: :post}
    # [error] MCP transport event: http_request_error
    # [error] MCP transport details: %{reason: "{:http_error, 404, \"{\\\"error\\\":\\\"Not found\\\",\\\"endpoints\\\"
    # :{\\\"/health\\\":\\\"Health check\\\",\\\"/sse\\\":\\\"SSE endpoint for MCP clients (GET)\\\",\\\"
    # /messages?sessionId=X\\\":\\\"Message endpoint for MCP clients (POST)\\\",\\\"/api/tweet/:id\\\":\\\
    # "Direct API - Get tweet (params: format=json|markdown|blog)\\\",\\\"
    # /deploy\\\":\\\"GitHub webhook - auto deploy (POST)\\\"}}\"}"}
    # "tweetsave_mcp" => %{
    #   id: "tweetsave_mcp",
    #   name: "TweetSave",
    #   icon: "hero-chat-bubble-left-right-solid",
    #   description: "TweetSave MCP endpoint for social content retrieval workflows.",
    #   editable: true,
    #   defaults: %{
    #     type: "remote",
    #     status: "enabled",
    #     timeout_ms: 5000,
    #     url: "https://mcp.tweetsave.org/sse",
    #     headers: %{},
    #     secret_headers: %{},
    #     environments: %{},
    #     secret_environments: %{},
    #     settings: %{}
    #   }
    # }
  }

  @doc """
  Returns the compile-time catalog of built-in predefined MCP endpoints.

  Each entry is keyed by a stable `predefined_id` string and carries display metadata
  (`name`, `icon`, `description`, `editable`) plus `defaults` used when enabling the
  endpoint via `enable_predefined/1`.
  """
  @spec predefined_catalog() :: map()
  def predefined_catalog, do: @predefined

  @doc """
  Returns all persisted MCP endpoints ordered by name ascending.

  Does not include unpersisted predefined entries. Use `filter_mcp_endpoints/2`
  when you need the merged catalog view for the BO listing page.
  """
  @spec list_mcp_endpoints() :: [Endpoint.t()]
  def list_mcp_endpoints do
    Endpoint
    |> order_by([e], asc: e.name)
    |> Repo.all()
  end

  @doc """
  Returns a paginated, filtered view of MCP endpoints for the BO listing page.

  Merges persisted DB entries with any predefined entries not yet in the DB, then applies
  `name` (case-insensitive substring), `type` (`"local"` | `"remote"` | `"all"`), and
  `status` (`"enabled"` | `"disabled"` | `"all"`) filters from the `filters` map.
  Results are sorted by name (case-insensitive) before pagination.

  Returns `{entries, total_count}` where each entry is a flat display map (see private
  `entry_from_endpoint/1` for the shape). Secrets are not decrypted in this view.

  ## Options

  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — entries per page (default: `20`)
  """
  @spec filter_mcp_endpoints(map(), keyword()) :: {[map()], non_neg_integer()}
  def filter_mcp_endpoints(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    entries =
      filters
      |> persisted_entries()
      |> merge_missing_predefined_entries()
      |> apply_entry_filters(filters)
      |> Enum.sort_by(&String.downcase(Map.get(&1, :name, "")))

    total = length(entries)

    page_entries =
      entries
      |> Enum.drop(max(page - 1, 0) * per_page)
      |> Enum.take(per_page)

    {page_entries, total}
  end

  @doc """
  Fetches a persisted MCP endpoint by ID, raising `Ecto.NoResultsError` if not found.
  """
  @spec get_mcp_endpoint!(integer() | String.t()) :: Endpoint.t()
  def get_mcp_endpoint!(id), do: Repo.get!(Endpoint, id)

  @doc """
  Fetches a persisted MCP endpoint by ID, returning `nil` if not found.
  """
  @spec get_mcp_endpoint(integer() | String.t()) :: Endpoint.t() | nil
  def get_mcp_endpoint(id), do: Repo.get(Endpoint, id)

  @doc """
  Fetches a persisted MCP endpoint by its `predefined_id` string, returning `nil` if not found.

  Used to check whether a predefined entry has already been enabled before deciding
  whether to insert or update in `enable_predefined/1`.
  """
  @spec get_by_predefined_id(String.t()) :: Endpoint.t() | nil
  def get_by_predefined_id(predefined_id) when is_binary(predefined_id) do
    Repo.get_by(Endpoint, predefined_id: predefined_id)
  end

  @doc """
  Returns an `Ecto.Changeset` for tracking form changes without persisting.

  Used by LiveView forms to validate and display errors before the user submits.
  Does not encrypt secrets — encryption runs only on `create_mcp_endpoint/1` and
  `update_mcp_endpoint/2`.
  """
  @spec change_mcp_endpoint(Endpoint.t(), map()) :: Changeset.t()
  def change_mcp_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  @doc """
  Inserts a new MCP endpoint after encrypting all secret fields.

  Secret fields (`secret_headers`, `secret_environments`) are encrypted via
  `Zaq.Types.EncryptedString` before insert. Returns `{:ok, endpoint}` or
  `{:error, changeset}` on validation or encryption failure.
  """
  @spec create_mcp_endpoint(map()) :: {:ok, Endpoint.t()} | {:error, Changeset.t()}
  def create_mcp_endpoint(attrs \\ %{}) do
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> encrypt_secret_maps()
    |> Repo.insert()
  end

  @doc """
  Updates a persisted MCP endpoint, encrypting secrets and validating editability.

  Rejects updates to non-editable predefined endpoints (returns `{:error, changeset}`
  with a `:base` error). Blank secret values preserve the existing encrypted value
  rather than overwriting with an empty string.
  """
  @spec update_mcp_endpoint(Endpoint.t(), map()) :: {:ok, Endpoint.t()} | {:error, Changeset.t()}
  def update_mcp_endpoint(%Endpoint{} = endpoint, attrs) do
    endpoint
    |> Endpoint.changeset(attrs)
    |> validate_editable_predefined()
    |> encrypt_secret_maps()
    |> Repo.update()
  end

  @doc """
  Deletes a persisted MCP endpoint after validating it can be removed.

  Returns `{:error, changeset}` with a `:base` error if:
  - The endpoint is a non-editable predefined entry
  - The endpoint is currently assigned to one or more configured agents (lists them by name)
  """
  @spec delete_mcp_endpoint(Endpoint.t()) :: {:ok, Endpoint.t()} | {:error, Changeset.t()}
  def delete_mcp_endpoint(%Endpoint{} = endpoint) do
    endpoint
    |> Changeset.change()
    |> validate_editable_predefined()
    |> validate_not_assigned_to_agents()
    |> case do
      %Changeset{valid?: true} -> Repo.delete(endpoint)
      %Changeset{} = changeset -> {:error, changeset}
    end
  end

  @doc """
  Enables a predefined MCP endpoint by its catalog ID, upserting it in the DB.

  Looks up the predefined catalog entry, merges its defaults with `status: "enabled"`,
  then inserts if no persisted record exists or updates the existing one.
  Returns `{:error, :unknown_predefined_mcp}` if `predefined_id` is not in the catalog.
  """
  @spec enable_predefined(String.t()) :: {:ok, Endpoint.t()} | {:error, Changeset.t() | atom()}
  def enable_predefined(predefined_id) when is_binary(predefined_id) do
    case Map.get(@predefined, predefined_id) do
      nil ->
        {:error, :unknown_predefined_mcp}

      predefined ->
        attrs =
          predefined.defaults
          |> Map.put(:name, predefined.name)
          |> Map.put(:status, "enabled")
          |> Map.put(:predefined_id, predefined.id)

        case get_by_predefined_id(predefined_id) do
          nil ->
            create_mcp_endpoint(attrs)

          %Endpoint{} = endpoint ->
            update_mcp_endpoint(endpoint, attrs)
        end
    end
  end

  @doc """
  Connects to an MCP endpoint and lists its available tools without persisting anything.

  Accepts either a loaded `Endpoint` struct or a DB ID (integer or string). Resolves the
  struct when an ID is given, returning `{:error, :endpoint_not_found}` if missing.
  Delegates to `Runtime.test_list_tools/2` for the actual connection and tool discovery.

  Used by the BO to validate endpoint configuration before saving.
  """
  @spec test_list_tools(Endpoint.t() | integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def test_list_tools(endpoint_or_id, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_or_id) do
      Runtime.test_list_tools(endpoint, opts)
    end
  end

  defp resolve_endpoint(%Endpoint{} = endpoint), do: {:ok, endpoint}

  defp resolve_endpoint(id) do
    case get_mcp_endpoint(id) do
      %Endpoint{} = endpoint -> {:ok, endpoint}
      nil -> {:error, :endpoint_not_found}
    end
  end

  defp persisted_entries(filters) do
    filters
    |> build_filter_query()
    |> Repo.all()
    |> Enum.map(&entry_from_endpoint/1)
  end

  defp merge_missing_predefined_entries(entries) do
    present = MapSet.new(entries, & &1.predefined_id)

    missing_entries =
      @predefined
      |> Map.values()
      |> Enum.reject(&MapSet.member?(present, &1.id))
      |> Enum.map(&entry_from_predefined/1)

    entries ++ missing_entries
  end

  defp apply_entry_filters(entries, filters) do
    entries
    |> filter_by_name(Map.get(filters, "name", ""))
    |> filter_by_type(Map.get(filters, "type", "all"))
    |> filter_by_status(Map.get(filters, "status", "all"))
  end

  defp filter_by_name(entries, ""), do: entries

  defp filter_by_name(entries, name) when is_binary(name) do
    down = String.downcase(String.trim(name))
    Enum.filter(entries, &String.contains?(String.downcase(&1.name), down))
  end

  defp filter_by_type(entries, "all"), do: entries

  defp filter_by_type(entries, type) when type in ["local", "remote"] do
    Enum.filter(entries, &(&1.type == type))
  end

  defp filter_by_type(entries, _), do: entries

  defp filter_by_status(entries, "all"), do: entries

  defp filter_by_status(entries, status) when status in ["enabled", "disabled"] do
    Enum.filter(entries, &(&1.status == status))
  end

  defp filter_by_status(entries, _), do: entries

  defp build_filter_query(filters) do
    Endpoint
    |> QueryFilters.maybe_filter_ilike(Map.get(filters, "name", ""), :name)
    |> maybe_filter_type(Map.get(filters, "type", "all"))
    |> maybe_filter_status(Map.get(filters, "status", "all"))
    |> order_by([e], asc: e.name)
  end

  defp maybe_filter_type(query, type) when type in ["local", "remote"] do
    from(e in query, where: e.type == ^type)
  end

  defp maybe_filter_type(query, _), do: query

  defp maybe_filter_status(query, status) when status in ["enabled", "disabled"] do
    from(e in query, where: e.status == ^status)
  end

  defp maybe_filter_status(query, _), do: query

  defp entry_from_endpoint(%Endpoint{} = endpoint) do
    predefined = endpoint.predefined_id && Map.get(@predefined, endpoint.predefined_id)

    %{
      id: endpoint.id,
      persisted?: true,
      predefined?: is_binary(endpoint.predefined_id),
      predefined_id: endpoint.predefined_id,
      editable: endpoint_editable?(endpoint.predefined_id),
      icon: predefined && predefined.icon,
      description: predefined && predefined.description,
      auto_enabled: predefined_auto_enabled?(predefined),
      name: endpoint.name,
      type: endpoint.type,
      status: endpoint.status,
      timeout_ms: endpoint.timeout_ms,
      command: endpoint.command,
      args: endpoint.args,
      url: endpoint.url,
      headers: endpoint.headers,
      secret_headers: endpoint.secret_headers,
      environments: endpoint.environments,
      secret_environments: endpoint.secret_environments,
      settings: endpoint.settings,
      endpoint: endpoint
    }
  end

  defp entry_from_predefined(predefined) do
    %{
      id: "predefined:#{predefined.id}",
      persisted?: false,
      predefined?: true,
      predefined_id: predefined.id,
      editable: predefined.editable,
      icon: predefined.icon,
      description: Map.get(predefined, :description),
      auto_enabled: predefined_auto_enabled?(predefined),
      name: predefined.name,
      type: predefined.defaults.type,
      status: "disabled",
      timeout_ms: predefined.defaults.timeout_ms,
      command: Map.get(predefined.defaults, :command),
      args: Map.get(predefined.defaults, :args, []),
      url: Map.get(predefined.defaults, :url),
      headers: Map.get(predefined.defaults, :headers, %{}),
      secret_headers: %{},
      environments: Map.get(predefined.defaults, :environments, %{}),
      secret_environments: %{},
      settings: Map.get(predefined.defaults, :settings, %{})
    }
  end

  defp predefined_auto_enabled?(%{defaults: %{status: "enabled"}}), do: true
  defp predefined_auto_enabled?(_), do: false

  defp endpoint_editable?(nil), do: true

  defp endpoint_editable?(predefined_id) when is_binary(predefined_id) do
    case Map.get(@predefined, predefined_id) do
      %{editable: editable} when is_boolean(editable) -> editable
      _ -> true
    end
  end

  defp validate_editable_predefined(%Changeset{} = changeset) do
    predefined_id = Changeset.get_field(changeset, :predefined_id)

    if endpoint_editable?(predefined_id) do
      changeset
    else
      Changeset.add_error(changeset, :base, "predefined MCP is not editable")
    end
  end

  defp validate_not_assigned_to_agents(%Changeset{} = changeset) do
    endpoint_id = Changeset.get_field(changeset, :id)

    case agents_using_endpoint(endpoint_id) do
      [] ->
        changeset

      agent_names ->
        message =
          [
            "This MCP endpoint is currently used by custom agents:",
            Enum.map_join(agent_names, "\n", &"- #{&1}"),
            "",
            "Remove this MCP endpoint from these agents first, then try deleting it again."
          ]
          |> Enum.join("\n")

        Changeset.add_error(changeset, :base, message)
    end
  end

  defp agents_using_endpoint(endpoint_id) when is_integer(endpoint_id) do
    ConfiguredAgent
    |> where([a], ^endpoint_id in a.enabled_mcp_endpoint_ids)
    |> select([a], a.name)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp agents_using_endpoint(_), do: []

  defp encrypt_secret_maps(%Changeset{} = changeset) do
    Enum.reduce_while(@secret_fields, changeset, fn field, acc ->
      case encrypt_secret_map_field(acc, field) do
        {:ok, next_changeset} -> {:cont, next_changeset}
        {:error, failed_changeset} -> {:halt, failed_changeset}
      end
    end)
  end

  defp encrypt_secret_map_field(%Changeset{} = changeset, field) do
    existing = field_existing_map(changeset, field)

    input_map =
      case Changeset.get_change(changeset, field) do
        nil -> existing
        map when is_map(map) -> map
        _ -> %{}
      end

    case encrypt_secret_values(input_map, existing) do
      {:ok, encrypted_map} ->
        {:ok, Changeset.put_change(changeset, field, encrypted_map)}

      {:error, reason} ->
        {:error, secret_encryption_error(changeset, field, reason)}
    end
  end

  defp encrypt_secret_values(input_map, existing_map)
       when is_map(input_map) and is_map(existing_map) do
    input_map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case encrypt_or_preserve_value(value, Map.get(existing_map, key)) do
        {:ok, :drop} ->
          {:cont, {:ok, acc}}

        {:ok, encrypted} ->
          {:cont, {:ok, Map.put(acc, key, encrypted)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp encrypt_or_preserve_value(value, existing_value) when value in [nil, ""] do
    case existing_value do
      existing when is_binary(existing) and existing != "" -> {:ok, existing}
      _ -> {:ok, :drop}
    end
  end

  defp encrypt_or_preserve_value(value, _existing_value) when is_binary(value) do
    if EncryptedString.encrypted?(value) do
      {:ok, value}
    else
      EncryptedString.encrypt(value)
    end
  end

  defp encrypt_or_preserve_value(_value, _existing_value), do: {:error, :invalid_secret_value}

  defp field_existing_map(%Changeset{data: data}, field) do
    case Map.get(data, field) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp secret_encryption_error(changeset, field, :missing_encryption_key) do
    Changeset.add_error(
      changeset,
      field,
      "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, :invalid_encryption_key) do
    Changeset.add_error(
      changeset,
      field,
      "could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, _reason) do
    Changeset.add_error(changeset, field, "could not be encrypted")
  end
end
