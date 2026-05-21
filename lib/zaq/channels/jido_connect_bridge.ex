defmodule Zaq.Channels.JidoConnectBridge do
  @moduledoc """
  DataSource bridge for jido_connect-backed providers.

  Credentials and grants are resolved exclusively through `Zaq.Engine.Connect`
  and mapped to runtime contracts by `Zaq.Channels.JidoConnectBridge.RuntimeMapper`.

  ## Adding a provider connector in this bridge

  Use this path when the provider should run on the jido_connect implementation
  bridge.

  1. Enable or build the connector.
     - Enable an existing `jido_connect_*` provider connector when available.
     - If missing, build a new connector/integration in the jido_connect layer.
     - Ensure the provider exposes action/trigger tool ids that this bridge can
       resolve through `resolve_action_spec/3` and webhook trigger resolution.

  2. Surface the provider in Data Sources configuration.
     - Add/update the BO Data Sources provider entry so users can select it.
     - Ensure provider/channel configuration resolves to this bridge via
       `Zaq.Channels.Bridge` mapping (in `config.exs`).

  3. Configure provider auth and verify behavior.
     - Configure credential/grant records through `Zaq.Engine.Connect` (via BO screens).
     - Validate OAuth profile and required scopes when the provider uses OAuth.
     - Verify end-to-end actions used by this bridge: list/get/create/update/
       delete/search/download files, permissions listing, webhook watch/receive,
       and export options as applicable.

  4. Update field normalization when needed.
     - Review `Zaq.Channels.JidoConnectBridge.FieldNormalization` for provider-
       specific query, field, or mime-type normalization needs.
     - Add normalization only when connector contracts differ from ZAQ-facing
       params; keep connector-specific logic isolated there.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.DataSourceBridge
  use Zaq.Channels.Bridge

  alias Jido.Connect.Authorization
  alias Jido.Connect.Catalog.ToolEntry
  alias Zaq.Channels.Bridge
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Channels.JidoConnectBridge.FieldNormalization
  alias Zaq.Channels.JidoConnectBridge.RuntimeMapper
  alias Zaq.Channels.JidoConnectBridge.WebhookWorker
  alias Zaq.Channels.ProviderCatalog
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
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
    params =
      params
      |> maybe_embed_permissions_projection(config)
      |> maybe_apply_standard_list_filters()

    with {:ok, payload} <- invoke_intent(config, :list_items, params) do
      files = read_list(payload, [:files, "files"], []) |> Enum.filter(&is_map/1)
      {:ok, build_item_record_page(files, params, payload)}
    end
  end

  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :create_item, params),
         {:ok, record} <- map_file_from_payload(payload) do
      {:ok, %{status: "created", record: record}}
    end
  end

  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :get_item_metadata, params),
         {:ok, record} <- map_file_from_payload(payload) do
      {:ok, %{record: record}}
    end
  end

  @impl true
  def update_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :update_item, params),
         {:ok, record} <- map_file_from_payload(payload) do
      {:ok, %{status: "updated", record: record}}
    end
  end

  @impl true
  def delete_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :delete_item, params) do
      {:ok, %{status: "deleted", result: payload}}
    end
  end

  @impl true
  def search_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, payload} <- invoke_intent(config, :search_items, params) do
      map_file_page(payload, params)
    end
  end

  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    params = maybe_apply_default_export_mime_type(config, params)

    with {:ok, payload} <- invoke_intent(config, :download_items, params),
         {:ok, record} <- map_downloaded_document_record(payload, params) do
      {:ok, %{record: record}}
    end
  end

  @impl true
  def export_options(config, params) when is_map(config) and is_map(params) do
    case invoke_intent(config, :get_export_options, params) do
      {:ok, payload} ->
        normalized =
          payload
          |> extract_export_formats_map()
          |> DataSourceBridge.normalize_export_formats_map()

        {:ok,
         %{
           native_types: Map.keys(normalized) |> Enum.sort(),
           export_formats_by_native_type: normalized
         }}

      _ ->
        default_export_options_response()
    end
  end

  defp extract_export_formats_map(payload) when is_map(payload) do
    about = read_any(payload, [:about, "about"]) || %{}

    read_any(about, [:export_formats, "export_formats"]) ||
      read_any(payload, [:export_formats, "export_formats"]) ||
      %{}
  end

  defp extract_export_formats_map(_), do: %{}

  defp default_export_options_response,
    do: {:ok, %{native_types: [], export_formats_by_native_type: %{}}}

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

  defp map_file_from_payload(payload) when is_map(payload) do
    raw = read_any(payload, [:file, "file"]) || payload

    if is_map(raw) do
      {:ok, map_file_record(raw)}
    else
      {:error, :unsupported}
    end
  rescue
    _ -> {:error, :unsupported}
  end

  defp map_file_from_payload(_), do: {:error, :unsupported}

  defp map_downloaded_document_record(payload, params) when is_map(payload) and is_map(params) do
    with content_payload when is_map(content_payload) <-
           read_any(payload, [:file_content, "file_content"]),
         file_id when is_binary(file_id) and file_id != "" <-
           resolve_downloaded_file_id(content_payload, params) do
      {:ok, build_downloaded_record(file_id, content_payload, payload)}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp map_downloaded_document_record(_, _), do: {:error, :unsupported}

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp resolve_downloaded_file_id(content_payload, params) do
    read_stringish(content_payload, [:file_id, "file_id"]) ||
      read_stringish(params, [:file_id, "file_id"]) ||
      read_stringish(params, [:document_id, "document_id"])
  end

  defp extract_downloaded_content(content_payload) do
    declared_encoding = read_stringish(content_payload, [:encoding, "encoding"])
    raw_content = read_any(content_payload, [:content, "content"])

    if declared_encoding == "rows" do
      case raw_content do
        rows when is_list(rows) -> {rows, "rows"}
        _ -> {[], "rows"}
      end
    else
      text_content = read_stringish(content_payload, [:content, "content"])
      base64_content = read_stringish(content_payload, [:content_base64, "content_base64"])

      cond do
        is_binary(text_content) -> {text_content, "utf-8"}
        is_binary(base64_content) -> {base64_content, "base64"}
        true -> {nil, nil}
      end
    end
  end

  defp build_downloaded_record(file_id, content_payload, payload) do
    mime_type = read_stringish(content_payload, [:mime_type, "mime_type"])
    size = read_integer(content_payload, [:size, "size"])
    {content, encoding} = extract_downloaded_content(content_payload)

    %Record{
      id: file_id,
      kind: :file,
      content: content,
      mime_type: mime_type,
      size: size,
      lifecycle_state: :active,
      attributes:
        %{}
        |> maybe_put_attr("encoding", encoding)
        |> maybe_put_attr("mime_type", mime_type),
      raw: payload
    }
  end

  defp map_file_page(payload, params) when is_map(payload) and is_map(params) do
    files = read_list(payload, [:files, "files"], []) |> Enum.filter(&is_map/1)

    {:ok, build_item_record_page(files, params, payload)}
  end

  defp build_item_record_page(files, params, payload)
       when is_list(files) and is_map(params) and is_map(payload) do
    next_cursor = read_stringish(payload, [:next_page_token, "next_page_token"])
    page_size = map_get_integer(params, [:page_size, "page_size"])

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
    }
  end

  @impl true
  def capability_snapshot(config) when is_map(config) do
    with {:ok, tools} <- provider_tools(config.provider) do
      {resolved, unsupported} = resolve_capabilities(config.provider, tools)

      {:ok,
       %{
         required: DataSourceBridge.required_capabilities(),
         resolved: resolved,
         unsupported: unsupported,
         labels: DataSourceBridge.capability_meta()
       }}
    end
  end

  defp resolve_capabilities(provider, tools) do
    DataSourceBridge.required_capabilities()
    |> Enum.reduce({%{}, []}, fn capability, {acc_resolved, acc_unsupported} ->
      case resolve_capability_ref(provider, tools, capability) do
        {:ok, ref} -> {Map.put(acc_resolved, capability, ref), acc_unsupported}
        _ -> {acc_resolved, [capability | acc_unsupported]}
      end
    end)
    |> then(fn {resolved, unsupported} -> {resolved, Enum.reverse(unsupported)} end)
  end

  defp resolve_capability_ref(_provider, tools, :watch_changes_webhook) do
    case find_webhook_watch_trigger(tools) do
      nil -> {:error, :unsupported}
      trigger -> {:ok, trigger.id}
    end
  end

  defp resolve_capability_ref(_provider, tools, :receive_change_webhook) do
    case find_webhook_watch_trigger(tools) do
      nil -> {:error, :unsupported}
      trigger -> {:ok, trigger.id}
    end
  end

  defp resolve_capability_ref(provider, tools, capability) do
    case resolve_action_spec(tools, capability, provider) do
      {:ok, action} -> {:ok, action.id}
      _ -> {:error, :unsupported}
    end
  end

  @impl true
  def download_resource(config, resource, params)
      when is_map(config) and is_map(resource) and is_map(params),
      do: {:error, :unsupported}

  @impl true
  def setup_listener(config, params) when is_map(config) and is_map(params),
    do: watch_changes(config, params)

  @impl true
  def teardown_listener(config, params) when is_map(config) and is_map(params),
    do: unwatch_changes(config, params)

  @impl true
  def watch_changes(config, params) when is_map(config) and is_map(params) do
    mechanism = map_get_string(params, [:mechanism, "mechanism"]) || "webhook"

    with :ok <- ensure_supported_watch_mechanism(mechanism),
         {:ok, trigger} <- resolve_watch_trigger(config.provider, mechanism) do
      {:ok,
       %{
         mechanism: mechanism,
         trigger_id: trigger.id,
         provider: config.provider,
         status: "watch_ready"
       }}
    end
  end

  @impl true
  def unwatch_changes(config, _params) when is_map(config),
    do: :ok

  @doc """
  Handles an incoming data source webhook delivery.

  The `payload` is expected to include request metadata used by provider-specific
  verifiers (headers, query params, and raw body). Returns `{:ok, %{trigger_id,
  delivery}}` when the webhook is verified, normalized, and dispatched.
  """
  @impl true
  def handle_webhook(config, payload) when is_map(config) and is_map(payload) do
    with {:ok, trigger} <- resolve_webhook_trigger(config.provider),
         {:ok, verifier} <- webhook_verifier_for(config.provider),
         {:ok, delivery} <- verifier.verify_and_normalize(trigger, payload),
         {:ok, delivery_map} <- delivery_to_map(delivery),
         {:ok, job} <- enqueue_webhook_job(config, payload, trigger, delivery_map) do
      {:ok, %{accepted: true, job_id: job.id}}
    end
  end

  @doc false
  @spec process_verified_webhook_job(map()) :: :ok | {:error, term()} | {:cancel, term()}
  def process_verified_webhook_job(args) when is_map(args) do
    with {:ok, config} <- fetch_webhook_config(args),
         {:ok, trigger} <- fetch_webhook_trigger(args),
         {:ok, payload} <- fetch_webhook_payload(args),
         {:ok, delivery_map} <- fetch_webhook_delivery(args),
         {:ok, record} <- load_changed_record(config, delivery_map),
         :ok <- dispatch_record_changed(config, payload, trigger, delivery_map, record) do
      :ok
    else
      {:cancel, _reason} = cancel -> cancel
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_webhook_job_args, other}}
    end
  end

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
  def oauth_default_scopes(config) when is_map(config) do
    provider = Map.get(config, :provider) || Map.get(config, "provider")

    case provider_required_scopes(provider) do
      scopes when is_list(scopes) ->
        normalized =
          scopes
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        {:ok, normalized}

      _ ->
        {:ok, []}
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

    if is_nil(credential_id) or credential_id == "" do
      {:error, :missing_credential_id}
    else
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
  end

  defp oauth_module_for(provider), do: ProviderCatalog.oauth_module(to_string(provider))

  defp oauth_profile_for(provider) do
    with {:ok, integration} <- integration_module_for(provider),
         {:ok, auth_profiles} <- Jido.Connect.auth_profiles(integration),
         profile when not is_nil(profile) <- Enum.find(auth_profiles, &(&1.kind == :oauth2)) do
      {:ok, profile}
    else
      {:error, reason} = error ->
        maybe_resolve_oauth_profile_from_catalog(provider, reason, error)

      nil ->
        {:error, :unsupported}
    end
  end

  defp maybe_resolve_oauth_profile_from_catalog(provider, reason, original_error) do
    if unknown_integration_error?(reason) do
      with {:ok, integration} <- integration_module_from_catalog(to_string(provider)),
           {:ok, auth_profiles} <- Jido.Connect.auth_profiles(integration),
           profile when not is_nil(profile) <- Enum.find(auth_profiles, &(&1.kind == :oauth2)) do
        {:ok, profile}
      else
        nil -> {:error, :unsupported}
        {:error, _} = error -> error
      end
    else
      original_error
    end
  end

  defp unknown_integration_error?(%{reason: :unknown_integration}), do: true
  defp unknown_integration_error?(_), do: false

  defp integration_module_for(provider) do
    provider = to_string(provider)

    with {:error, _} <- integration_module_from_config(provider) do
      integration_module_from_catalog(provider)
    end
  end

  defp integration_module_from_config(provider) when is_binary(provider) do
    with {:ok, cfg} <- provider_cfg(provider),
         integration when is_atom(integration) <- Map.get(cfg, :integration) do
      {:ok, integration}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp integration_module_from_catalog(provider) when is_binary(provider) do
    provider_key = Bridge.provider_to_bridge_key(provider)
    module = catalog_discover_module()

    with true <- module_supports?(module, :discover, 0) || {:error, :unsupported},
         entries when is_list(entries) <- module.discover(),
         %{module: integration} when is_atom(integration) <-
           Enum.find(entries, fn entry -> Map.get(entry, :id) == provider_key end) do
      {:ok, integration}
    else
      _ -> {:error, :unsupported}
    end
  rescue
    _ -> {:error, :unsupported}
  end

  defp catalog_discover_module do
    module = catalog_module()
    if module_supports?(module, :discover, 0), do: module, else: Jido.Connect.Catalog
  end

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

  defp provider_tools(provider) do
    provider_key = Bridge.provider_to_bridge_key(to_string(provider))
    module = catalog_module()

    with true <- module_supports?(module, :tools, 1) || {:error, :unsupported},
         tools <- module.tools(provider: provider_key) do
      finalize_provider_tools(tools, provider_key)
    end
  rescue
    _ -> {:error, :unsupported}
  end

  defp finalize_provider_tools({:error, _} = error, _provider_key), do: error

  defp finalize_provider_tools(tools, provider_key) do
    tools
    |> List.wrap()
    |> Enum.filter(fn tool ->
      to_string(map_get_atom(tool, [:provider, "provider"])) == to_string(provider_key)
    end)
    |> case do
      [] -> {:error, :unsupported}
      list -> {:ok, list}
    end
  end

  defp invoke_intent(config, intent, params) when is_map(config) and is_map(params) do
    with {:ok, runtime} <- runtime_ctx(config),
         {:ok, action} <- resolve_action(config.provider, intent, params) do
      runtime = normalize_runtime_profile(runtime, action)
      normalized_params = FieldNormalization.normalize_all(config.provider, action.id, params)

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

      case call_provider_tool(action, normalized_params, opts, config.provider) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> {:error, sanitize_error(reason)}
      end
    end
  end

  defp resolve_action(provider, capability, params)
       when capability == :download_items and is_map(params) do
    with {:ok, tools} <- provider_tools(provider) do
      resolve_action_spec(tools, capability, provider, params)
    end
  end

  defp resolve_action(provider, capability, _params), do: resolve_action(provider, capability)

  defp call_provider_tool(action, params, opts, provider)
       when is_map(action) and is_map(params) do
    module = catalog_module()

    with true <- module_supports?(module, :call_tool, 3) || {:error, :unsupported} do
      provider_ref =
        map_get_atom(action, [:provider, "provider"]) ||
          Bridge.provider_to_bridge_key(to_string(provider))

      module.call_tool({provider_ref, action.id}, params, opts)
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
    permissions = map_embedded_permissions(raw)

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
      change_type: nil,
      lifecycle_state: :active,
      deleted_at: nil,
      permissions: permissions,
      attributes: %{},
      raw: raw
    }
  end

  defp map_permission_record(raw) when is_map(raw) do
    id = fetch_required_string!(raw, ["id", :id, "permission_id", :permission_id], "permission")

    %Record{
      id: id,
      kind: :permission,
      name:
        read_stringish(raw, [
          "displayName",
          :displayName,
          "display_name",
          :display_name,
          "emailAddress",
          :emailAddress,
          "email_address",
          :email_address
        ]),
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
      change_type: nil,
      lifecycle_state: :active,
      deleted_at: nil,
      attributes: %{},
      raw: raw
    }
  end

  defp map_embedded_permissions(raw) when is_map(raw) do
    case read_any(raw, ["permissions", :permissions]) do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(&map_permission_record/1)

      _ ->
        nil
    end
  end

  defp maybe_embed_permissions_projection(params, %{provider: provider} = _config)
       when is_map(params) and (is_binary(provider) or is_atom(provider)) do
    if truthy?(Map.get(params, :include_permissions) || Map.get(params, "include_permissions")) do
      enrich_permissions_projection(provider, params)
    else
      params
    end
  end

  defp maybe_embed_permissions_projection(params, _), do: params

  defp enrich_permissions_projection(provider, params) do
    provider = to_string(provider)

    with {:ok, action} <- resolve_action(provider, :list_items),
         true <- action_supports_fields_input?(provider, action) do
      maybe_set_provider_permission_fields(provider, params)
    else
      _ -> params
    end
  end

  defp action_supports_fields_input?(provider, action)
       when (is_binary(provider) or is_atom(provider)) and is_map(action) do
    module = catalog_module()

    provider_ref =
      map_get_atom(action, [:provider, "provider"]) ||
        Bridge.provider_to_bridge_key(to_string(provider))

    with true <- module_supports?(module, :describe_tool, 2),
         {:ok, descriptor} <- module.describe_tool({provider_ref, action.id}, []),
         true <- descriptor_supports_fields_input?(descriptor) do
      true
    else
      _ -> supports_fields_input?(action)
    end
  end

  defp action_supports_fields_input?(_provider, action), do: supports_fields_input?(action)

  defp descriptor_supports_fields_input?(%{input: input}) when is_list(input),
    do: Enum.any?(input, &fields_input?/1)

  defp descriptor_supports_fields_input?(%{"input" => input}) when is_list(input),
    do: Enum.any?(input, &fields_input?/1)

  defp descriptor_supports_fields_input?(_), do: false

  defp supports_fields_input?(%{input: input}) when is_list(input) do
    Enum.any?(input, &fields_input?/1)
  end

  defp supports_fields_input?(_), do: false

  defp fields_input?(entry) when is_map(entry) do
    case Map.get(entry, :name) || Map.get(entry, "name") do
      :fields -> true
      "fields" -> true
      _ -> false
    end
  end

  defp fields_input?(_), do: false

  defp maybe_set_provider_permission_fields("google_drive", params) do
    permission_fields =
      "permissions(id,type,role,emailAddress,domain,displayName,allowFileDiscovery,deleted,expirationTime)"

    fields = Map.get(params, :fields) || Map.get(params, "fields")

    merged_fields =
      cond do
        is_binary(fields) and String.contains?(fields, "permissions(") ->
          fields

        is_binary(fields) and String.contains?(fields, "files(") ->
          Regex.replace(
            ~r/files\((.*?)\)/,
            fields,
            fn _all, inner ->
              "files(#{inner},#{permission_fields})"
            end,
            global: false
          )

        is_binary(fields) ->
          fields <> ",files(#{permission_fields})"

        true ->
          default_google_drive_list_fields_with_permissions(permission_fields)
      end

    params
    |> Map.put(:fields, merged_fields)
    |> Map.put("fields", merged_fields)
  end

  defp maybe_set_provider_permission_fields(_provider, params), do: params

  defp default_google_drive_list_fields_with_permissions(permission_fields) do
    file_fields =
      "id,name,mimeType,description,webViewLink,webContentLink,iconLink,thumbnailLink,size,md5Checksum,createdTime,modifiedTime,parents,owners,shared,trashed,starred,driveId"

    "nextPageToken,files(#{file_fields},#{permission_fields})"
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

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
    |> maybe_from_struct()
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

  defp maybe_from_struct(%_{} = struct), do: Map.from_struct(struct)
  defp maybe_from_struct(map), do: map

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

  defp ensure_supported_watch_mechanism("webhook"), do: :ok
  defp ensure_supported_watch_mechanism(_), do: {:error, :unsupported}

  defp resolve_watch_trigger(provider, "webhook") do
    resolve_webhook_trigger(provider)
  end

  defp resolve_watch_trigger(_provider, _mechanism), do: {:error, :unsupported}

  defp resolve_webhook_trigger(provider) do
    with {:ok, tools} <- provider_tools(provider),
         trigger when not is_nil(trigger) <- find_webhook_watch_trigger(tools) do
      {:ok, trigger}
    else
      nil -> {:error, :unsupported}
      _ -> {:error, :unsupported}
    end
  end

  defp webhook_verifier_for(provider) do
    with {:ok, cfg} <- provider_cfg(provider),
         verifier when is_atom(verifier) <- Map.get(cfg, :webhook_verifier) do
      {:ok, verifier}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp enqueue_webhook_job(config, payload, trigger, delivery_map) do
    args = %{
      "config_id" => Map.get(config, :id),
      "provider" => to_string(config.provider),
      "trigger_id" => trigger.id,
      "payload" => payload,
      "delivery" => delivery_map
    }

    args
    |> webhook_worker_module().new()
    |> oban_module().insert()
    |> case do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:webhook_enqueue_failed, reason}}
    end
  end

  defp fetch_webhook_config(%{"config_id" => id, "provider" => provider}) do
    case Repo.get(ChannelConfig, id) do
      %ChannelConfig{kind: "data_source", provider: config_provider} = config ->
        if to_string(config_provider) == to_string(provider) do
          {:ok, config}
        else
          {:cancel, :provider_mismatch}
        end

      _ ->
        {:cancel, :config_not_found}
    end
  end

  defp fetch_webhook_config(_), do: {:cancel, :missing_config}

  defp fetch_webhook_trigger(%{"trigger_id" => trigger_id}) when is_binary(trigger_id),
    do: {:ok, %{id: trigger_id}}

  defp fetch_webhook_trigger(_), do: {:cancel, :missing_trigger_id}

  defp fetch_webhook_payload(%{"payload" => payload}) when is_map(payload), do: {:ok, payload}
  defp fetch_webhook_payload(_), do: {:cancel, :missing_payload}

  defp fetch_webhook_delivery(%{"delivery" => delivery}) when is_map(delivery),
    do: {:ok, delivery}

  defp fetch_webhook_delivery(_), do: {:cancel, :missing_delivery}

  defp dispatch_record_changed(config, payload, trigger, delivery, record) do
    event =
      Event.new(
        %{
          provider: config.provider,
          config_id: Map.get(config, :id),
          trigger_id: trigger.id,
          delivery: delivery,
          payload: payload,
          record: record
        },
        :engine,
        opts: [action: :data_source_record_changed]
      )

    case node_router_module().dispatch(event).response do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp delivery_to_map(delivery) when is_struct(delivery) do
    {:ok, Map.from_struct(delivery)}
  rescue
    _ -> {:error, :invalid_delivery}
  end

  defp delivery_to_map(delivery) when is_map(delivery), do: {:ok, delivery}

  defp delivery_to_map(_), do: {:error, :invalid_delivery}

  defp load_changed_record(config, delivery_map) do
    signal =
      Map.get(delivery_map, :normalized_signal) || Map.get(delivery_map, "normalized_signal") ||
        %{}

    file_id =
      read_stringish(signal, [:file_id, "file_id", :id, "id"]) ||
        read_stringish(signal, [:resource_id, "resource_id"])

    if is_nil(file_id) do
      {:error, :missing_record_id}
    else
      if deleted_signal?(signal),
        do: {:ok, tombstone_record(file_id, signal)},
        else: fetch_or_build_record(config, file_id, signal)
    end
  end

  defp fetch_or_build_record(config, file_id, signal) do
    case invoke_intent(config, :get_item_metadata, %{file_id: file_id}) do
      {:ok, payload} ->
        raw = read_any(payload, [:file, "file"]) || payload
        {:ok, map_file_record(raw) |> apply_signal_change(signal)}

      _ ->
        {:ok,
         %Record{id: file_id, kind: :file, raw: %{}, attributes: %{}}
         |> apply_signal_change(signal)}
    end
  end

  defp deleted_signal?(signal) when is_map(signal) do
    Map.get(signal, :removed) == true or
      Map.get(signal, "removed") == true or
      Map.get(signal, :deleted) == true or
      Map.get(signal, "deleted") == true or
      Map.get(signal, :change_type) in ["deleted", :deleted] or
      Map.get(signal, "change_type") in ["deleted", :deleted]
  end

  defp deleted_signal?(_), do: false

  defp tombstone_record(file_id, signal) do
    %Record{id: file_id, kind: :file, raw: %{}, attributes: %{}}
    |> apply_signal_change(signal)
  end

  defp apply_signal_change(%Record{} = record, signal) when is_map(signal) do
    change_type = signal_change_type(signal)
    lifecycle_state = lifecycle_state_for_change(change_type)
    deleted_at = signal_deleted_at(signal)

    %{record | change_type: change_type, lifecycle_state: lifecycle_state, deleted_at: deleted_at}
  end

  defp apply_signal_change(%Record{} = record, _), do: record

  defp signal_change_type(signal) when is_map(signal) do
    case Map.get(signal, :change_type) || Map.get(signal, "change_type") do
      value when value in ["created", :created] -> :created
      value when value in ["deleted", :deleted] -> :deleted
      _ -> if(deleted_signal?(signal), do: :deleted, else: :updated)
    end
  end

  defp signal_change_type(_), do: :updated

  defp lifecycle_state_for_change(:deleted), do: :deleted
  defp lifecycle_state_for_change(_), do: :active

  defp signal_deleted_at(signal) when is_map(signal) do
    case Map.get(signal, :time) || Map.get(signal, "time") do
      value when is_binary(value) -> parse_iso_datetime(value)
      _ -> nil
    end
  end

  defp signal_deleted_at(_), do: nil

  defp parse_iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_iso_datetime(_), do: nil

  defp resolve_action(provider, capability) do
    with {:ok, tools} <- provider_tools(provider) do
      resolve_action_spec(tools, capability, provider)
    end
  end

  defp resolve_action_spec(_tools, capability, _provider)
       when capability in [:watch_changes_webhook, :receive_change_webhook],
       do: {:error, :unsupported}

  defp resolve_action_spec(tools, :list_items, provider),
    do: resolve_action_by_candidates(tools, provider, :list_items)

  defp resolve_action_spec(tools, :count_items, provider),
    do: resolve_action_by_candidates(tools, provider, :list_items)

  defp resolve_action_spec(tools, :list_principals, provider),
    do: resolve_action_by_candidates(tools, provider, :list_principals)

  defp resolve_action_spec(tools, :count_principals, provider),
    do: resolve_action_by_candidates(tools, provider, :list_principals)

  defp resolve_action_spec(tools, :get_item_metadata, provider),
    do: resolve_action_by_candidates(tools, provider, :get_item_metadata)

  defp resolve_action_spec(tools, :list_item_versions, provider),
    do: resolve_action_by_candidates(tools, provider, :list_item_versions)

  defp resolve_action_spec(tools, :download_items, provider),
    do: resolve_action_by_candidates(tools, provider, :download_items)

  defp resolve_action_spec(tools, :get_export_options, provider),
    do: resolve_action_by_candidates(tools, provider, :get_export_options)

  defp resolve_action_spec(tools, :create_item, provider),
    do: resolve_action_by_candidates(tools, provider, :create_item)

  defp resolve_action_spec(tools, :update_item, provider),
    do: resolve_action_by_candidates(tools, provider, :update_item)

  defp resolve_action_spec(tools, :delete_item, provider),
    do: resolve_action_by_candidates(tools, provider, :delete_item)

  defp resolve_action_spec(tools, :search_items, provider),
    do: resolve_action_by_candidates(tools, provider, :search_items)

  defp resolve_action_spec(_tools, _capability, _provider), do: {:error, :unsupported}

  defp resolve_action_spec(tools, :download_items, provider, params)
       when is_list(tools) and is_map(params) do
    if export_requested?(params) do
      resolve_action_by_candidates(tools, provider, :export_items)
      |> case do
        {:ok, _} = ok -> ok
        _ -> resolve_action_by_candidates(tools, provider, :download_items)
      end
    else
      resolve_action_by_candidates(tools, provider, :download_items)
    end
  end

  defp resolve_action_by_candidates(tools, provider, capability)
       when is_list(tools) and not is_nil(provider) do
    prefix = provider_tool_prefix(provider)

    capability
    |> capability_tool_candidates(prefix)
    |> Enum.find_value(fn id -> find_action_by_id(tools, id) end)
    |> case do
      nil -> {:error, :unsupported}
      action -> {:ok, action}
    end
  end

  defp resolve_action_by_candidates(_tools, _provider, _capability), do: {:error, :unsupported}

  defp capability_tool_candidates(:list_items, prefix),
    do: ["#{prefix}.files.list", "#{prefix}.file.list"]

  defp capability_tool_candidates(:list_principals, prefix),
    do: ["#{prefix}.permissions.list", "#{prefix}.permission.list"]

  defp capability_tool_candidates(:get_item_metadata, prefix), do: ["#{prefix}.file.get"]

  defp capability_tool_candidates(:list_item_versions, prefix),
    do: ["#{prefix}.revisions.list", "#{prefix}.revision.list"]

  defp capability_tool_candidates(:download_items, prefix), do: ["#{prefix}.file.download"]
  defp capability_tool_candidates(:export_items, prefix), do: ["#{prefix}.file.export"]
  defp capability_tool_candidates(:get_export_options, prefix), do: ["#{prefix}.about.get"]
  defp capability_tool_candidates(:create_item, prefix), do: ["#{prefix}.file.create"]
  defp capability_tool_candidates(:update_item, prefix), do: ["#{prefix}.file.update"]

  defp capability_tool_candidates(:delete_item, prefix), do: ["#{prefix}.file.delete"]

  defp capability_tool_candidates(:search_items, prefix),
    do: ["#{prefix}.files.search", "#{prefix}.file.search", "#{prefix}.files.list"]

  defp capability_tool_candidates(_capability, _prefix), do: []

  defp export_requested?(params) when is_map(params) do
    case read_stringish(params, [:export_mime_type, "export_mime_type"]) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp maybe_apply_default_export_mime_type(config, params)
       when is_map(config) and is_map(params) do
    if export_requested?(params), do: params, else: put_default_export_mime_type(config, params)
  end

  defp put_default_export_mime_type(config, params) do
    document_mime_type = read_stringish(params, [:document_mime_type, "document_mime_type"])

    export_mime_type =
      config
      |> Map.get(:settings, %{})
      |> Map.get("connect", %{})
      |> Map.get("export_defaults_by_native_mime", %{})
      |> Map.get(document_mime_type)

    with value when is_binary(value) <- export_mime_type,
         trimmed when trimmed != "" <- String.trim(value) do
      params
      |> Map.put(:export_mime_type, trimmed)
      |> Map.put("export_mime_type", trimmed)
    else
      _ -> params
    end
  end

  defp provider_tool_prefix(provider) do
    provider
    |> to_string()
    |> String.trim()
    |> String.replace("_", ".")
  end

  defp find_action_by_id(tools, id) when is_list(tools) and is_binary(id) do
    Enum.find(tools, fn
      %ToolEntry{id: tool_id, type: :action} -> tool_id == id
      %{id: tool_id} = tool -> tool_id == id and map_get_atom(tool, [:type, "type"]) == :action
      _ -> false
    end)
  end

  defp find_action_by_id(_tools, _id), do: nil

  defp find_webhook_watch_trigger(tools) do
    Enum.find(tools, &match_webhook_watch_trigger?/1)
  end

  defp match_webhook_watch_trigger?(%ToolEntry{} = tool),
    do: tool.type == :trigger and tool.trigger_kind == :webhook and tool.verb == :watch

  defp match_webhook_watch_trigger?(tool) when is_map(tool),
    do:
      map_get_atom(tool, [:type, "type"]) == :trigger and
        map_get_atom(tool, [:trigger_kind, "trigger_kind", :kind, "kind"]) == :webhook and
        map_get_atom(tool, [:verb, "verb"]) == :watch

  defp match_webhook_watch_trigger?(_), do: false

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
    with {:ok, tools} <- provider_tools(provider),
         {:ok, snapshot} <- capability_snapshot(%{provider: provider}),
         scopes <- collect_required_scopes(tools, snapshot, provider) do
      scopes
    else
      _ -> nil
    end
  end

  defp collect_required_scopes(tools, %{resolved: resolved}, provider)
       when is_list(tools) and is_map(resolved) do
    provider_ref = provider || map_get_atom(List.first(tools), [:provider, "provider"])

    resolved
    |> Map.keys()
    |> Enum.reduce([], fn capability, acc ->
      case resolve_action_spec(tools, capability, provider_ref) do
        {:ok, action} -> acc ++ List.wrap(Map.get(action, :scopes, []))
        _ -> acc
      end
    end)
    |> Enum.map(fn
      scope when is_binary(scope) -> String.trim(scope)
      scope when is_atom(scope) -> scope |> to_string() |> String.trim()
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
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

  defp webhook_worker_module,
    do: Application.get_env(:zaq, :jido_connect_bridge_webhook_worker_module, WebhookWorker)

  defp oban_module,
    do: Application.get_env(:zaq, :jido_connect_bridge_oban_module, Oban)

  defp catalog_module,
    do:
      Application.get_env(
        :zaq,
        :jido_connect_bridge_catalog_module,
        Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module, Jido.Connect.Catalog)
      )

  defp module_supports?(module, fun, arity)
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp module_supports?(_module, _fun, _arity), do: false
end
