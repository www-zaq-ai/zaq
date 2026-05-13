defmodule Zaq.Channels.JidoConnectBridge do
  @moduledoc """
  DataSource bridge for jido_connect-backed providers.

  Credentials and grants are resolved exclusively through `Zaq.Engine.Connect`
  and mapped to runtime contracts by `Zaq.Channels.JidoConnectBridge.RuntimeMapper`.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.DataSourceBridge
  use Zaq.Channels.Bridge

  alias Jido.Connect.Authorization
  alias Jido.Connect.ScopeRequirements
  alias Zaq.Channels.Bridge
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Channels.JidoConnectBridge.RuntimeMapper
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter
  require Logger

  @impl true
  def auth_handshake(config, params) when is_map(config) and is_map(params),
    do: {:error, :unsupported}

  @impl true
  def list_resources(config, params) when is_map(config) and is_map(params) do
    list_files(config, params)
  end

  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    params = maybe_apply_standard_list_filters(params)

    with {:ok, payload} <- invoke_intent(config, :list_items, params) do
      files = read_list(payload, [:files, "files"], []) |> Enum.filter(&is_map/1)
      next_cursor = read_stringish(payload, [:next_page_token, "next_page_token"])
      page_size = map_get_integer(params, [:page_size, "page_size"])

      {:ok,
       %RecordPage{
         resource_type: :item,
         records: Enum.map(files, &map_file_record/1),
         pagination: %{
           cursor: next_cursor,
           has_more?: is_binary(next_cursor) and next_cursor != "",
           page_size: page_size,
           pages_loaded: 1,
           truncated?: false
         },
         stats: %{scanned: length(files), returned: length(files)},
         filters: map_get_map(params, [:filters, "filters"]),
         metadata: %{}
       }}
    end
  end

  @impl true
  def list_permissions(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :list_principals, params) do
      permissions =
        payload
        |> read_list([:permissions, "permissions"], [])
        |> Enum.filter(&is_map/1)

      next_cursor = read_stringish(payload, [:next_page_token, "next_page_token"])
      page_size = map_get_integer(params, [:page_size, "page_size"])

      {:ok,
       %RecordPage{
         resource_type: :permission,
         records: Enum.map(permissions, &map_permission_record/1),
         pagination: %{
           cursor: next_cursor,
           has_more?: is_binary(next_cursor) and next_cursor != "",
           page_size: page_size,
           pages_loaded: 1,
           truncated?: false
         },
         stats: %{scanned: length(permissions), returned: length(permissions)},
         filters: map_get_map(params, [:filters, "filters"]),
         metadata: %{}
       }}
    end
  end

  @impl true
  def capability_snapshot(config) when is_map(config) do
    with {:ok, integration} <- integration_for_provider(config.provider),
         {:ok, actions} <- jido_connect_module().actions(integration) do
      {resolved, unsupported} = resolve_capabilities(actions)

      {:ok,
       %{
         required: DataSourceBridge.required_capabilities(),
         resolved: resolved,
         unsupported: unsupported,
         labels: DataSourceBridge.capability_meta()
       }}
    end
  end

  defp resolve_capabilities(actions) do
    DataSourceBridge.required_capabilities()
    |> Enum.reduce({%{}, []}, fn capability, {acc_resolved, acc_unsupported} ->
      case resolve_action_spec(actions, capability) do
        {:ok, action} -> {Map.put(acc_resolved, capability, action.id), acc_unsupported}
        _ -> {acc_resolved, [capability | acc_unsupported]}
      end
    end)
    |> then(fn {resolved, unsupported} -> {resolved, Enum.reverse(unsupported)} end)
  end

  @impl true
  def download_resource(config, resource, params)
      when is_map(config) and is_map(resource) and is_map(params),
      do: {:error, :unsupported}

  @impl true
  def setup_listener(config, params) when is_map(config) and is_map(params),
    do: {:error, :unsupported}

  @impl true
  def teardown_listener(config, params) when is_map(config) and is_map(params),
    do: {:error, :unsupported}

  @impl true
  def channel_stats(config, params) when is_map(config) and is_map(params) do
    files_result = list_files(config, params)

    entries =
      case files_result do
        {:ok, %RecordPage{records: records}} -> Enum.map(records, & &1.raw)
        _ -> []
      end

    {base_stats, files_error} =
      case files_result do
        {:ok, _payload} ->
          {build_stats_from_resources(entries), nil}

        {:error, :unsupported} ->
          {%{files_count: nil, folders_count: nil, principals_count: nil, root_folders: nil}, nil}

        {:error, reason} ->
          Logger.warning("datasource list_files failed: #{inspect(reason)}")

          {%{files_count: nil, folders_count: nil, principals_count: nil, root_folders: nil},
           reason}
      end

    {principals_count, principals_error} = maybe_collect_principals_count(config, entries)

    stats = Map.put(base_stats, :principals_count, principals_count)
    stats = maybe_put_stats_error(stats, files_error || principals_error)
    {:ok, stats}
  end

  defp maybe_collect_principals_count(_config, []), do: {0, nil}

  defp maybe_collect_principals_count(config, entries) do
    limit = 25

    entries
    |> Enum.take(limit)
    |> Enum.reduce_while(MapSet.new(), &collect_file_principals(config, &1, &2))
    |> case do
      {nil, reason} -> {nil, reason}
      set -> {MapSet.size(set), nil}
    end
  end

  defp collect_file_principals(config, file, acc) do
    case read_stringish(file, ["id", :id, "file_id", :file_id]) do
      nil ->
        {:cont, acc}

      file_id ->
        case list_permissions(config, %{file_id: file_id}) do
          {:ok, %RecordPage{records: records}} ->
            principals =
              records
              |> Enum.map(& &1.raw)
              |> Enum.flat_map(&principal_keys/1)
              |> MapSet.new()

            {:cont, MapSet.union(acc, principals)}

          {:error, :unsupported} ->
            {:halt,
             {nil,
              %{code: :unsupported_capability, message: "Permissions listing is unsupported."}}}

          {:error, reason} ->
            Logger.warning(
              "datasource list_permissions failed for #{file_id}: #{inspect(reason)}"
            )

            {:halt, {nil, reason}}
        end
    end
  end

  defp maybe_put_stats_error(stats, nil), do: stats
  defp maybe_put_stats_error(stats, error), do: Map.put(stats, :_error, error)

  @impl true
  def oauth_authorize_url(config, params) when is_map(config) and is_map(params) do
    with {:ok, runtime} <- runtime_ctx_for_oauth(config),
         {:ok, oauth_module} <- oauth_module_for(config.provider),
         {:ok, profile} <- oauth_profile_for(config.provider) do
      opts = [
        client_id: runtime.credential.client_id,
        redirect_uri: runtime.redirect_uri,
        state: Map.get(params, "state"),
        authorize_url: profile.authorize_url
      ]

      scope = oauth_scope_for_authorize(runtime.credential, params, config.provider)
      opts = maybe_put_scope_opt(opts, scope)
      opts = maybe_put_provider_authorize_opts(opts, config.provider)

      {:ok, oauth_module.authorize_url(opts)}
    end
  end

  @impl true
  def oauth_exchange_code(config, params) when is_map(config) and is_map(params) do
    with {:ok, runtime} <- runtime_ctx_for_oauth(config),
         {:ok, oauth_module} <- oauth_module_for(config.provider),
         {:ok, profile} <- oauth_profile_for(config.provider),
         {:ok, token} <-
           oauth_module.exchange_code(Map.get(params, "code"),
             client_id: runtime.credential.client_id,
             client_secret: runtime.credential.client_secret,
             redirect_uri: runtime.redirect_uri,
             token_url: profile.token_url
           ) do
      {:ok, normalize_oauth_token(token)}
    end
  end

  @impl true
  def oauth_refresh_token(config, params) when is_map(config) and is_map(params) do
    with {:ok, runtime} <- runtime_ctx_for_oauth(config),
         {:ok, oauth_module} <- oauth_module_for(config.provider),
         {:ok, profile} <- oauth_profile_for(config.provider),
         {:ok, token} <-
           oauth_module.refresh_token(
             Map.get(params, "refresh_token"),
             maybe_put_scope_opt(
               [
                 client_id: runtime.credential.client_id,
                 client_secret: runtime.credential.client_secret,
                 token_url: profile.token_url
               ],
               Map.get(params, "scope")
             )
           ) do
      {:ok, normalize_oauth_token(token)}
    end
  end

  @impl true
  def build_runtime_specs(_config), do: {:ok, {nil, []}}

  @impl true
  def to_internal(_payload, _config), do: {:error, :unsupported}

  defp runtime_ctx(%{provider: provider, id: id}) do
    grant =
      engine_get_active_grant(%{
        provider: provider,
        resource_type: "data_source",
        resource_id: id,
        owner_type: "org",
        owner_id: nil
      })

    with %{credential_id: credential_id} = grant <- grant,
         {:ok, credential} <- engine_fetch_credential(credential_id) do
      {:ok,
       %{
         connection: RuntimeMapper.to_connection(grant),
         lease: RuntimeMapper.to_credential_lease(grant, credential),
         grant: grant,
         credential: credential
       }}
    else
      nil -> {:error, :missing_active_grant}
      {:error, :not_found} -> {:error, :credential_not_found}
    end
  end

  defp runtime_ctx_for_oauth(%{provider: provider} = config) do
    credential_id =
      config
      |> Map.get(:settings, %{})
      |> Map.get("connect", %{})
      |> Map.get("credential_id")

    with {:ok, credential} <- engine_fetch_credential(credential_id),
         redirect_uri when is_binary(redirect_uri) <-
           engine_oauth_redirect_uri_for(provider) do
      {:ok,
       %{
         provider: provider,
         credential: credential,
         redirect_uri: redirect_uri
       }}
    else
      {:error, _} = error -> error
    end
  end

  defp oauth_module_for("google_drive"), do: {:ok, Jido.Connect.Google.OAuth}
  defp oauth_module_for(_provider), do: {:error, :unsupported}

  defp oauth_profile_for(provider) do
    with {:ok, integration} <- integration_module_for(provider),
         {:ok, auth_profiles} <- Jido.Connect.auth_profiles(integration),
         profile when not is_nil(profile) <- Enum.find(auth_profiles, &(&1.kind == :oauth2)) do
      {:ok, profile}
    else
      nil -> {:error, :unsupported}
      {:error, _} = error -> error
    end
  end

  defp integration_module_for("google_drive"), do: {:ok, Jido.Connect.Google.Drive}
  defp integration_module_for(_provider), do: {:error, :unsupported}

  defp normalize_oauth_token(token) when is_map(token) do
    %{
      access_token: Map.get(token, :access_token),
      refresh_token: Map.get(token, :refresh_token),
      expires_at: Map.get(token, :expires_at),
      scopes: Map.get(token, :scope, [])
    }
  end

  defp maybe_put_scope_opt(opts, scope) when is_list(opts) do
    case oauth_scope_opt(scope) do
      nil -> opts
      scopes -> Keyword.put(opts, :scope, scopes)
    end
  end

  defp oauth_scope_opt(nil), do: nil

  defp oauth_scope_opt(scope) when is_list(scope) do
    normalized = Enum.filter(scope, &(is_binary(&1) and String.trim(&1) != ""))
    if normalized == [], do: nil, else: normalized
  end

  defp oauth_scope_opt(scope) when is_binary(scope) do
    scope
    |> String.split(" ", trim: true)
    |> oauth_scope_opt()
  end

  defp oauth_scope_for_authorize(credential, params, provider) do
    credential_scopes =
      credential
      |> Map.get(:scopes, [])
      |> oauth_scope_opt()

    requested_scope = Map.get(params, "scope") |> oauth_scope_opt()

    credential_scopes || requested_scope || provider_required_scopes(provider)
  end

  defp maybe_put_provider_authorize_opts(opts, "google_drive") do
    Keyword.put_new(opts, :access_type, "offline")
  end

  defp maybe_put_provider_authorize_opts(opts, _provider), do: opts

  defp provider_cfg(provider) do
    key = Bridge.provider_to_bridge_key(to_string(provider))

    case get_in(Application.get_env(:zaq, :channels, %{}), [key]) do
      %{integration: _} = cfg -> {:ok, cfg}
      _ -> {:error, {:provider_not_configured, provider}}
    end
  end

  defp invoke_intent(config, intent, params) when is_map(config) and is_map(params) do
    with {:ok, runtime} <- runtime_ctx(config),
         {:ok, integration} <- integration_for_provider(config.provider),
         {:ok, action} <- resolve_action(integration, intent) do
      runtime = normalize_runtime_profile(runtime, action)

      opts = [
        context: %{
          tenant_id: "zaq",
          actor: %{},
          connection: runtime.connection,
          claims: %{},
          metadata: %{}
        },
        credential_lease: runtime.lease
      ]

      case jido_connect_module().invoke(integration, action.id, params, opts) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> {:error, sanitize_error(reason)}
      end
    end
  end

  # Temporary helper until jido_connect provides a generic filter compiler.
  # Accepts ZAQ-level `filters` and compiles provider-side list query params.
  defp maybe_apply_standard_list_filters(params) when is_map(params) do
    case Map.get(params, "filters") || Map.get(params, :filters) do
      filters when is_map(filters) ->
        query = build_provider_list_query(filters)

        params
        |> Map.put("query", query)
        |> Map.put(:query, query)

      _ ->
        params
    end
  end

  defp map_file_record(raw) when is_map(raw) do
    id = fetch_required_string!(raw, ["id", :id, "file_id", :file_id], "file")
    parent_ids = read_parent_ids(raw)

    %Record{
      id: id,
      kind: infer_item_kind(raw),
      name: read_stringish(raw, ["name", :name, "title", :title]),
      parent_id: List.first(parent_ids),
      parent_ids: parent_ids,
      mime_type: read_stringish(raw, ["mime_type", :mime_type]),
      path: read_stringish(raw, ["path", :path]),
      url: read_stringish(raw, ["web_view_link", :web_view_link]),
      size: read_integer(raw, ["size", :size]),
      description: read_stringish(raw, ["description", :description]),
      owners: read_owners(raw),
      icon: read_stringish(raw, ["icon_link", :icon_link, "icon", :icon]),
      created_at: read_datetime(raw, ["created_time", :created_time, "created_at", :created_at]),
      modified_at:
        read_datetime(raw, ["modified_time", :modified_time, "modified_at", :modified_at]),
      attributes: %{},
      raw: raw
    }
  end

  defp map_permission_record(raw) when is_map(raw) do
    id = fetch_required_string!(raw, ["id", :id], "permission")

    %Record{
      id: id,
      kind: :permission,
      name: read_stringish(raw, ["displayName", :displayName, "emailAddress", :emailAddress]),
      parent_id: nil,
      parent_ids: [],
      mime_type: nil,
      path: nil,
      url: nil,
      size: nil,
      description: nil,
      owners: [],
      icon: nil,
      created_at: nil,
      modified_at: nil,
      attributes: %{},
      raw: raw
    }
  end

  defp fetch_required_string!(map, keys, kind_label) do
    case read_stringish(map, keys) do
      value when is_binary(value) and value != "" and value != "nil" -> value
      _ -> raise "missing required id while mapping #{kind_label} record"
    end
  end

  defp infer_item_kind(raw) do
    type = read_stringish(raw, ["type", :type])
    mime = read_stringish(raw, ["mimeType", :mimeType, "mime_type", :mime_type])

    if type in ["folder", "directory"] or mime == "application/vnd.google-apps.folder",
      do: :folder,
      else: :file
  end

  defp read_parent_ids(raw) do
    case read_any(raw, ["parents", :parents]) do
      list when is_list(list) ->
        Enum.filter(list, &is_binary/1)

      _ ->
        case read_stringish(raw, ["parent_id", :parent_id, "parent", :parent]) do
          nil -> []
          value -> [value]
        end
    end
  end

  defp read_owners(raw) do
    case read_any(raw, ["owners", :owners]) do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(&normalize_owner/1)

      map when is_map(map) ->
        [normalize_owner(map)]

      _ ->
        []
    end
  end

  defp normalize_owner(owner) when is_map(owner) do
    %{
      display_name: read_stringish(owner, ["displayName", :displayName, "name", :name]),
      photo_url: read_stringish(owner, ["photoLink", :photoLink]),
      email: read_stringish(owner, ["emailAddress", :emailAddress, "email", :email]),
      id: read_stringish(owner, ["id", :id]),
      raw: owner
    }
  end

  defp read_datetime(raw, keys) do
    case read_stringish(raw, keys) do
      nil ->
        nil

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end

  defp read_integer(raw, keys) do
    case read_any(raw, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_provider_list_query(filters) when is_map(filters) do
    kind = map_get_string(filters, [:kind, "kind"])
    parent = map_get_string(filters, [:parent, "parent"])
    trashed = Map.get(filters, :trashed, Map.get(filters, "trashed", false))

    clauses =
      []
      |> maybe_add_clause(kind == "folder", "mimeType = 'application/vnd.google-apps.folder'")
      |> maybe_add_clause(
        is_binary(parent) and String.trim(parent) != "",
        "'#{escape_query_value(parent)}' in parents"
      )
      |> maybe_add_clause(
        is_boolean(trashed),
        "trashed = #{if trashed, do: "true", else: "false"}"
      )

    Enum.join(clauses, " and ")
  end

  defp maybe_add_clause(clauses, true, clause), do: [clause | clauses]
  defp maybe_add_clause(clauses, false, _clause), do: clauses

  defp escape_query_value(value) when is_binary(value), do: String.replace(value, "'", "\\'")

  defp sanitize_error(%{message: message} = reason) when is_binary(message) do
    provider = map_get_string(reason, [:provider, "provider"])
    status = map_get_integer(reason, [:status, "status"])

    details =
      reason
      |> Map.get(:details, %{})
      |> sanitize_map()

    display_message = Map.get(details, "message") || message

    code =
      cond do
        status == 403 ->
          :provider_forbidden

        status == 401 ->
          :provider_unauthorized

        status == 429 ->
          :provider_rate_limited

        status == 404 ->
          :provider_not_found

        map_get_atom(reason, [:reason, "reason"]) == :unsupported_auth_profile ->
          :unsupported_auth_profile

        true ->
          :provider_error
      end

    %{
      code: code,
      provider: provider,
      status: status,
      retryable: status in [408, 409, 425, 429, 500, 502, 503, 504],
      message: message,
      display_message: display_message,
      details: details
    }
  end

  defp sanitize_error(reason) when is_binary(reason),
    do: %{code: :provider_error, message: reason}

  defp sanitize_error(reason) do
    %{code: :provider_error, message: inspect(reason)}
  end

  defp sanitize_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
    |> Map.new()
  end

  defp sanitize_map(_), do: %{}

  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value) when is_binary(value), do: value
  defp sanitize_value(value) when is_number(value), do: value
  defp sanitize_value(value) when is_boolean(value), do: value
  defp sanitize_value(nil), do: nil
  defp sanitize_value(_), do: "[omitted]"

  defp map_get_string(map, keys) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      other -> inspect(other)
    end
  end

  defp map_get_integer(map, keys) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp map_get_map(map, keys) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_get_atom(map, keys) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      value when is_atom(value) -> value
      _ -> nil
    end
  end

  defp integration_for_provider(provider) do
    with {:ok, cfg} <- provider_cfg(provider),
         integration when is_atom(integration) <- Map.get(cfg, :integration) do
      {:ok, integration}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp resolve_action(integration, capability) do
    with {:ok, actions} <- jido_connect_module().actions(integration) do
      resolve_action_spec(actions, capability)
    end
  end

  defp resolve_action_spec(actions, :list_items), do: find_action(actions, :file, :list)
  defp resolve_action_spec(actions, :count_items), do: find_action(actions, :file, :list)

  defp resolve_action_spec(actions, :list_principals),
    do: find_action(actions, :permission, :list)

  defp resolve_action_spec(actions, :count_principals),
    do: find_action(actions, :permission, :list)

  defp resolve_action_spec(actions, :get_item_metadata), do: find_action(actions, :file, :get)

  defp resolve_action_spec(actions, :list_item_versions),
    do: find_action(actions, :revision, :list)

  defp resolve_action_spec(actions, :download_items), do: find_action(actions, :file, :download)
  defp resolve_action_spec(actions, :create_item), do: find_action(actions, :file, :create)
  defp resolve_action_spec(actions, :update_item), do: find_action(actions, :file, :update)
  defp resolve_action_spec(_actions, _), do: {:error, :unsupported}

  defp find_action(actions, resource, verb) do
    case Enum.find(actions, &(&1.resource == resource and &1.verb == verb)) do
      nil -> {:error, :unsupported}
      action -> {:ok, action}
    end
  end

  defp normalize_runtime_profile(runtime, action) when is_map(runtime) do
    allowed_profiles = Authorization.operation_auth_profiles(action)
    owner_type = runtime.grant.owner_type |> to_string()
    preferred = owner_type_profile_candidates(owner_type)
    profile = Enum.find(preferred, &(&1 in allowed_profiles)) || List.first(allowed_profiles)

    %{
      runtime
      | connection: Map.put(runtime.connection, :profile, profile),
        lease: Map.put(runtime.lease, :profile, profile)
    }
  end

  defp owner_type_profile_candidates("org"), do: [:org, :user]
  defp owner_type_profile_candidates("app_user"), do: [:app_user, :user]
  defp owner_type_profile_candidates("user"), do: [:user]
  defp owner_type_profile_candidates(_), do: [:user]

  defp provider_required_scopes(provider) do
    with {:ok, integration} <- integration_for_provider(provider),
         {:ok, actions} <- jido_connect_module().actions(integration),
         {:ok, snapshot} <- capability_snapshot(%{provider: provider}),
         scopes <- collect_required_scopes(actions, snapshot) do
      scopes
    else
      _ -> nil
    end
  end

  defp collect_required_scopes(actions, %{resolved: resolved}) when is_map(resolved) do
    resolved
    |> Map.keys()
    |> Enum.reduce([], fn capability, acc ->
      with {:ok, action} <- resolve_action_spec(actions, capability),
           {:ok, scopes} <- ScopeRequirements.required_scopes(action, %{}, nil) do
        acc ++ scopes
      else
        _ -> acc
      end
    end)
    |> Enum.uniq()
  end

  defp build_stats_from_resources(resources) when is_list(resources) do
    entries = Enum.filter(resources, &is_map/1)

    folders = Enum.filter(entries, &folder_resource?/1)
    files = Enum.reject(entries, &folder_resource?/1)

    principals =
      entries
      |> Enum.flat_map(&resource_principals/1)
      |> MapSet.new()

    %{
      files_count: length(files),
      folders_count: length(folders),
      principals_count: MapSet.size(principals),
      root_folders:
        folders
        |> Enum.filter(&root_folder?/1)
        |> Enum.map(&folder_label/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp build_stats_from_resources(_),
    do: %{files_count: nil, folders_count: nil, principals_count: nil, root_folders: nil}

  defp folder_resource?(resource) when is_map(resource) do
    type = read_stringish(resource, ["type", :type])
    mime = read_stringish(resource, ["mimeType", :mimeType, "mime_type", :mime_type])

    type in ["folder", "directory"] or mime == "application/vnd.google-apps.folder"
  end

  defp root_folder?(resource) when is_map(resource) do
    case read_any(resource, ["parents", :parents, "parent_id", :parent_id, "parent", :parent]) do
      nil -> true
      [] -> true
      "" -> true
      _ -> false
    end
  end

  defp folder_label(resource) do
    read_stringish(resource, ["name", :name, "title", :title, "id", :id]) || "Unnamed"
  end

  defp resource_principals(resource) when is_map(resource) do
    permission_sets =
      [read_any(resource, ["permissions", :permissions]), read_any(resource, ["owners", :owners])]
      |> Enum.flat_map(fn
        nil -> []
        list when is_list(list) -> list
        map when is_map(map) -> [map]
        _ -> []
      end)

    Enum.flat_map(permission_sets, &principal_keys/1)
  end

  defp principal_keys(permission) when is_map(permission) do
    fields = [
      read_stringish(permission, ["id", :id]),
      read_stringish(permission, ["emailAddress", :emailAddress, "email", :email]),
      read_stringish(permission, ["domain", :domain]),
      read_stringish(permission, ["type", :type])
    ]

    case Enum.find(fields, &(is_binary(&1) and String.trim(&1) != "")) do
      nil -> []
      _ -> [Enum.map_join(fields, "|", &(&1 || ""))]
    end
  end

  defp principal_keys(_), do: []

  defp read_any(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp read_list(map, keys, default) when is_map(map) do
    case read_any(map, keys) do
      list when is_list(list) -> list
      _ -> default
    end
  end

  defp read_stringish(map, keys) do
    case read_any(map, keys) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp engine_get_active_grant(params) when is_map(params) do
    event = Event.new(params, :engine, opts: [action: :connect_get_active_grant])
    node_router_module().dispatch(event).response
  end

  defp engine_fetch_credential(credential_id) do
    event =
      Event.new(%{credential_id: credential_id}, :engine,
        opts: [action: :connect_fetch_credential]
      )

    node_router_module().dispatch(event).response
  end

  defp engine_oauth_redirect_uri_for(provider) do
    event =
      Event.new(%{provider: provider}, :engine, opts: [action: :connect_oauth_redirect_uri_for])

    node_router_module().dispatch(event).response
  end

  defp node_router_module,
    do: Application.get_env(:zaq, :jido_connect_bridge_node_router_module, NodeRouter)

  defp jido_connect_module,
    do: Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module, Jido.Connect)
end
