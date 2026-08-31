defmodule Zaq.Channels.DataSourceBridge do
  @moduledoc """
  DataSource-domain bridge routing and delegation helpers.

  This module is the Channels boundary for DataSource operations (auth,
  resource listing/download, listener setup/teardown, provider watch setup and
  teardown, and webhook handling). It resolves provider bridge modules via
  `Zaq.Channels.Bridge` and delegates transport-specific behavior to the
  concrete bridge implementation.

  Provider watch callbacks are intentionally provider-facing. Durable watch
  channel runtime state and checkpoints are stored by `Zaq.Engine.DataSources`,
  while watched-record filtering and document deletion are owned by
  `Zaq.Ingestion`.

  ## Adding a new Data Source provider

  There are two supported paths:

  1. Add a connector to an existing DataSource implementation bridge.
     - Current implementation bridges:
       - `Zaq.Channels.JidoConnectBridge`
     - Wire or enable the provider connector in that bridge's underlying
       integration stack.
     - Check the selected bridge moduledoc for provider-specific onboarding
       details and required follow-up steps.

  2. Add a new DataSource implementation bridge.
     - Define a bridge module under `lib/zaq/channels/`.
     - `@behaviour Zaq.Channels.Bridge`
     - `@behaviour Zaq.Channels.DataSourceBridge`
     - `use Zaq.Channels.Bridge`
     - Implement the callbacks declared in this module according to provider
       capabilities (return `{:error, :unsupported}` for unsupported actions).
     - Ensure provider resolution and runtime sync paths remain routed through
       `Zaq.Channels.Bridge`.

  File operations receive a normalized `Zaq.Events.TrustedContext` as their third callback
  argument. Identity and explicit permission bypass therefore remain separate from provider
  parameters and cannot be supplied by model-controlled request fields.
  """

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Events.TrustedContext

  @callback auth_handshake(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback list_resources(map(), map()) :: {:ok, RecordPage.t()} | {:error, term()}
  @callback download_resource(map(), map(), map()) :: {:ok, term()} | {:error, term()}
  @callback setup_listener(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback teardown_listener(map(), map()) :: :ok | {:error, term()}
  @callback watch_changes(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback unwatch_changes(map(), map()) :: :ok | {:error, term()}
  @callback watch_item(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback unwatch_item(map(), map()) :: :ok | {:ok, term()} | {:error, term()}
  @callback handle_webhook(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback oauth_authorize_url(map(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback oauth_exchange_code(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback oauth_refresh_token(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback oauth_default_scopes(map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback list_source_scopes(map(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback list_files(map(), map(), TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}
  @callback create_file(map(), map(), TrustedContext.t()) :: {:ok, map()} | {:error, term()}
  @callback get_file(map(), map(), TrustedContext.t()) :: {:ok, map()} | {:error, term()}
  @callback update_file(map(), map(), TrustedContext.t()) :: {:ok, map()} | {:error, term()}
  @callback delete_file(map(), map(), TrustedContext.t()) :: {:ok, map()} | {:error, term()}
  @callback search_files(map(), map(), TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}
  @callback download_document(map(), map(), TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}
  @callback list_permissions(map(), map(), TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}
  @callback replace_permissions(map(), map(), TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}
  @callback channel_stats(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback export_options(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_inspect(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_get(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_create(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_add_tab(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_update_values(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_append_values(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_clear_values(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_delete_tab(map(), map()) :: {:ok, map()} | {:error, term()}

  # Every callback above is optional. This module already dispatches through
  # `supports_callback?/3` and answers `{:error, :unsupported}` for anything a bridge does
  # not export, so partial implementation is the design, not an accident — a provider that
  # has no spreadsheets should not have to stub twelve sheet functions. Declaring them
  # optional makes the behaviour say what the dispatcher already does, and lets a narrow
  # bridge (`Zaq.Channels.DiskBridge`) still get compile-time checking on the callbacks it
  # does implement.
  @optional_callbacks auth_handshake: 2,
                      list_resources: 2,
                      download_resource: 3,
                      setup_listener: 2,
                      teardown_listener: 2,
                      watch_changes: 2,
                      unwatch_changes: 2,
                      watch_item: 2,
                      unwatch_item: 2,
                      handle_webhook: 2,
                      oauth_authorize_url: 2,
                      oauth_exchange_code: 2,
                      oauth_refresh_token: 2,
                      oauth_default_scopes: 1,
                      list_source_scopes: 2,
                      list_files: 3,
                      create_file: 3,
                      get_file: 3,
                      update_file: 3,
                      delete_file: 3,
                      search_files: 3,
                      download_document: 3,
                      list_permissions: 3,
                      replace_permissions: 3,
                      channel_stats: 2,
                      export_options: 2,
                      sheet_inspect: 2,
                      sheet_get: 2,
                      sheet_create: 2,
                      sheet_add_tab: 2,
                      sheet_update_values: 2,
                      sheet_append_values: 2,
                      sheet_clear_values: 2,
                      sheet_delete_tab: 2

  @required_capabilities [
    :list_items,
    :count_items,
    :list_principals,
    :count_principals,
    :get_item_metadata,
    :list_item_versions,
    :download_items,
    :create_item,
    :update_item,
    :delete_item,
    :manage_item_permissions,
    :search_items,
    :sheet_inspect,
    :sheet_get,
    :sheet_create,
    :sheet_add_tab,
    :sheet_update_values,
    :sheet_append_values,
    :sheet_clear_values,
    :sheet_delete_tab,
    :watch_changes_webhook,
    :receive_change_webhook
  ]

  @capability_meta %{
    list_items: "List files and folders",
    count_items: "Count files and folders",
    list_principals: "List users/principals with access",
    count_principals: "Count users/principals with access",
    get_item_metadata: "Get file/folder metadata",
    list_item_versions: "Get file/folder versions",
    download_items: "Download file/folder selection",
    create_item: "Add file",
    update_item: "Edit file",
    delete_item: "Delete a file/folder",
    manage_item_permissions: "Manage file/folder permissions",
    search_items: "Search for a file",
    sheet_inspect: "Inspect spreadsheet metadata",
    sheet_get: "Read sheet values or spreadsheet metadata",
    sheet_create: "Create a spreadsheet",
    sheet_add_tab: "Add a tab in a spreadsheet",
    sheet_update_values: "Update a sheet range",
    sheet_append_values: "Append rows to a sheet",
    sheet_clear_values: "Clear a sheet range",
    sheet_delete_tab: "Delete a tab in a spreadsheet",
    watch_changes_webhook: "Register webhook watch for change notifications",
    receive_change_webhook: "Verify and normalize webhook change payloads"
  }

  @doc "Runs provider auth handshake through the configured DataSource bridge."
  @spec auth_handshake(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def auth_handshake(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :auth_handshake, 2) || {:error, :unsupported} do
      bridge.auth_handshake(config, params)
    end
  end

  @doc "Lists provider resources through the configured DataSource bridge."
  @spec list_resources(atom() | String.t(), map()) :: {:ok, RecordPage.t()} | {:error, term()}
  def list_resources(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :list_resources, 2) || {:error, :unsupported} do
      bridge.list_resources(config, params)
    end
  end

  @doc "Downloads a provider resource through the configured DataSource bridge."
  @spec download_resource(atom() | String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def download_resource(provider, resource, params \\ %{})
      when is_map(resource) and is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :download_resource, 3) || {:error, :unsupported} do
      bridge.download_resource(config, resource, params)
    end
  end

  @doc "Sets up a provider listener through the configured DataSource bridge."
  @spec setup_listener(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def setup_listener(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :setup_listener, 2) || {:error, :unsupported} do
      bridge.setup_listener(config, params)
    end
  end

  @doc "Tears down a provider listener through the configured DataSource bridge."
  @spec teardown_listener(atom() | String.t(), map()) :: :ok | {:error, term()}
  def teardown_listener(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :teardown_listener, 2) || {:error, :unsupported} do
      bridge.teardown_listener(config, params)
    end
  end

  @doc "Starts provider change watch through the configured DataSource bridge."
  @spec watch_changes(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def watch_changes(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :watch_changes, 2) || {:error, :unsupported} do
      bridge.watch_changes(config, params)
    end
  end

  @doc "Stops provider change watch through the configured DataSource bridge."
  @spec unwatch_changes(atom() | String.t(), map()) :: :ok | {:error, term()}
  def unwatch_changes(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :unwatch_changes, 2) || {:error, :unsupported} do
      bridge.unwatch_changes(config, params)
    end
  end

  @doc "Starts provider watch registration for a specific data-source item."
  @spec watch_item(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def watch_item(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :watch_item, 2) || {:error, :unsupported} do
      bridge.watch_item(config, params)
    end
  end

  @doc "Stops provider watch registration for a specific data-source item."
  @spec unwatch_item(atom() | String.t(), map()) :: :ok | {:ok, term()} | {:error, term()}
  def unwatch_item(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :unwatch_item, 2) || {:error, :unsupported} do
      bridge.unwatch_item(config, params)
    end
  end

  @doc "Handles a provider webhook delivery through the configured DataSource bridge."
  @spec handle_webhook(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_webhook(provider, payload) when is_map(payload) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :handle_webhook, 2) || {:error, :unsupported} do
      bridge.handle_webhook(config, payload)
    end
  end

  @doc "Builds OAuth authorize URL through the configured DataSource bridge."
  @spec oauth_authorize_url(atom() | String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def oauth_authorize_url(provider, params) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :oauth_authorize_url, 2) || {:error, :unsupported} do
      bridge.oauth_authorize_url(config, params)
    end
  end

  @doc "Exchanges OAuth callback code through the configured DataSource bridge."
  @spec oauth_exchange_code(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def oauth_exchange_code(provider, params) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :oauth_exchange_code, 2) || {:error, :unsupported} do
      bridge.oauth_exchange_code(config, params)
    end
  end

  @doc "Refreshes OAuth token through the configured DataSource bridge."
  @spec oauth_refresh_token(atom() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def oauth_refresh_token(provider, params, opts \\ []) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider, opts),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :oauth_refresh_token, 2) || {:error, :unsupported} do
      bridge.oauth_refresh_token(config, params)
    end
  end

  @doc "Lists default OAuth scopes through the configured DataSource bridge."
  @spec oauth_default_scopes(atom() | String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def oauth_default_scopes(provider) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :oauth_default_scopes, 1) || {:error, :unsupported} do
      bridge.oauth_default_scopes(config)
    end
  end

  @doc "Lists source scopes exposed by one data-source config."
  @spec list_source_scopes(atom() | String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_source_scopes(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params) do
      if supports_callback?(bridge, :list_source_scopes, 2) do
        bridge.list_source_scopes(config, params)
      else
        {:ok, [default_source_scope(config)]}
      end
    end
  end

  @doc "Lists provider files through the configured DataSource bridge."
  @spec list_files(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, RecordPage.t()} | {:error, term()}
  def list_files(provider, params \\ %{}, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :list_files, 3) || {:error, :unsupported} do
      bridge.list_files(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Creates a provider file through the configured DataSource bridge."
  @spec create_file(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, map()} | {:error, term()}
  def create_file(provider, params \\ %{}, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :create_file, 3) || {:error, :unsupported} do
      bridge.create_file(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Gets a provider file by id through the configured DataSource bridge."
  @spec get_file(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, map()} | {:error, term()}
  def get_file(provider, params \\ %{}, context \\ %{}) when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :get_file, 3) || {:error, :unsupported} do
      bridge.get_file(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Updates a provider file through the configured DataSource bridge."
  @spec update_file(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, map()} | {:error, term()}
  def update_file(provider, params \\ %{}, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :update_file, 3) || {:error, :unsupported} do
      bridge.update_file(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Deletes the provider file identified by a canonical data-source record."
  @spec delete_file(Record.t(), map() | TrustedContext.t()) :: {:ok, map()} | {:error, term()}
  def delete_file(%Record{} = record, context \\ %{}) when is_map(context) do
    with {:ok, provider} <- record_provider(record),
         params <- delete_file_params(record),
         {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :delete_file, 3) || {:error, :unsupported} do
      bridge.delete_file(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Searches provider files through the configured DataSource bridge."
  @spec search_files(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, RecordPage.t()} | {:error, term()}
  def search_files(provider, params \\ %{}, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :search_files, 3) || {:error, :unsupported} do
      bridge.search_files(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Downloads a provider document through the configured DataSource bridge."
  @spec download_document(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, map()} | {:error, term()}
  def download_document(provider, params \\ %{}, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :download_document, 3) || {:error, :unsupported} do
      bridge.download_document(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Lists provider file permissions through the configured DataSource bridge."
  @spec list_permissions(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, RecordPage.t()} | {:error, term()}
  def list_permissions(provider, params, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :list_permissions, 3) || {:error, :unsupported} do
      bridge.list_permissions(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Replaces provider file permissions through the configured DataSource bridge."
  @spec replace_permissions(atom() | String.t(), map(), map() | TrustedContext.t()) ::
          {:ok, map()} | {:error, term()}
  def replace_permissions(provider, params, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :replace_permissions, 3) || {:error, :unsupported} do
      bridge.replace_permissions(config, params, TrustedContext.normalize(context))
    end
  end

  @doc "Fetches provider channel stats through the configured DataSource bridge."
  @spec channel_stats(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def channel_stats(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :channel_stats, 2) || {:error, :unsupported} do
      bridge.channel_stats(config, params)
    end
  end

  @doc "Fetches provider export options (native mime -> export mime types)."
  @spec export_options(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def export_options(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :export_options, 2) || {:error, :unsupported} do
      bridge.export_options(config, params)
    else
      {:error, :unsupported} -> {:ok, %{native_types: [], export_formats_by_native_type: %{}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Inspects spreadsheet metadata and tabs through the configured DataSource bridge."
  @spec sheet_inspect(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_inspect(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_inspect, 2) || {:error, :unsupported} do
      bridge.sheet_inspect(config, params)
    end
  end

  @doc "Reads cell values from a spreadsheet range through the configured DataSource bridge."
  @spec sheet_get(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_get(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_get, 2) || {:error, :unsupported} do
      bridge.sheet_get(config, params)
    end
  end

  @doc "Creates a spreadsheet through the configured DataSource bridge."
  @spec sheet_create(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_create(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_create, 2) || {:error, :unsupported} do
      bridge.sheet_create(config, params)
    end
  end

  @doc "Adds a tab to a spreadsheet through the configured DataSource bridge."
  @spec sheet_add_tab(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_add_tab(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_add_tab, 2) || {:error, :unsupported} do
      bridge.sheet_add_tab(config, params)
    end
  end

  @doc "Updates values in a spreadsheet through the configured DataSource bridge."
  @spec sheet_update_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_update_values(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_update_values, 2) || {:error, :unsupported} do
      bridge.sheet_update_values(config, params)
    end
  end

  @doc "Appends values in a spreadsheet through the configured DataSource bridge."
  @spec sheet_append_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_append_values(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_append_values, 2) || {:error, :unsupported} do
      bridge.sheet_append_values(config, params)
    end
  end

  @doc "Clears values in a spreadsheet through the configured DataSource bridge."
  @spec sheet_clear_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_clear_values(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_clear_values, 2) || {:error, :unsupported} do
      bridge.sheet_clear_values(config, params)
    end
  end

  @doc "Deletes a spreadsheet tab through the configured DataSource bridge."
  @spec sheet_delete_tab(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet_delete_tab(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- resolve_data_source_config(provider, params),
         true <- supports_callback?(bridge, :sheet_delete_tab, 2) || {:error, :unsupported} do
      bridge.sheet_delete_tab(config, params)
    end
  end

  defp resolve_data_source_config(provider, params) do
    case normalize_config_id(params) do
      {:ok, id} -> fetch_scoped_data_source_config(provider, id)
      :error -> fetch_unscoped_data_source_config(provider)
    end
  end

  defp fetch_unscoped_data_source_config(provider), do: Bridge.fetch_channel_config(provider)

  defp delete_file_params(%Record{} = record) do
    %{"file_id" => record_file_id(record)}
    |> maybe_put("config_id", record_config_id(record))
  end

  defp record_provider(%Record{} = record) do
    case record_attr(record, "provider") || record_attr(record, :provider) do
      provider when is_binary(provider) and provider != "" -> {:ok, provider}
      provider when is_atom(provider) and not is_nil(provider) -> {:ok, provider}
      _ -> {:error, {:invalid_record, :provider_required}}
    end
  end

  defp record_config_id(%Record{} = record),
    do: record_attr(record, "config_id") || record_attr(record, :config_id)

  defp record_file_id(%Record{id: id} = record),
    do:
      to_string(
        record_attr(record, "provider_record_id") || record_attr(record, :provider_record_id) ||
          id
      )

  defp record_attr(%Record{attributes: attrs}, key) when is_map(attrs), do: Map.get(attrs, key)
  defp record_attr(%Record{}, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_config_id(params) do
    case Map.get(params, "config_id") || Map.get(params, :config_id) do
      id when is_integer(id) ->
        {:ok, id}

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int_id, ""} -> {:ok, int_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp fetch_scoped_data_source_config(provider, id) do
    case Zaq.Repo.get(ChannelConfig, id) do
      %ChannelConfig{provider: prov, kind: "data_source", enabled: true} = config ->
        ensure_provider_match(config, provider, prov)

      %ChannelConfig{provider: prov, kind: "data_source", enabled: false} ->
        {:error, {:channel_disabled, prov}}

      _ ->
        {:error, {:channel_not_configured, provider}}
    end
  end

  defp ensure_provider_match(config, provider, scoped_provider) do
    if to_string(scoped_provider) == to_string(provider) do
      {:ok, config}
    else
      {:error, {:channel_not_configured, provider}}
    end
  end

  @doc "Returns globally required datasource capabilities."
  @spec required_capabilities() :: [atom()]
  def required_capabilities, do: @required_capabilities

  @doc "Returns capability labels for BO and diagnostics."
  @spec capability_meta() :: map()
  def capability_meta, do: @capability_meta

  @doc "Normalizes export format map values (native mime => non-empty unique mime types)."
  @spec normalize_export_formats_map(map()) :: map()
  def normalize_export_formats_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {native_mime, mime_types}, acc when is_binary(native_mime) and is_list(mime_types) ->
        values =
          mime_types
          |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
          |> Enum.uniq()

        if values == [], do: acc, else: Map.put(acc, native_mime, values)

      _, acc ->
        acc
    end)
  end

  def normalize_export_formats_map(_), do: %{}

  @doc "Returns connector capability resolution for a provider."
  @spec capability_snapshot(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def capability_snapshot(provider, params \\ %{}),
    do: Bridge.capability_snapshot(provider, params)

  @doc "Synchronizes runtime processes when a datasource config changes."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  def sync_config_runtime(before_config, %{provider: provider} = after_config) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider) do
      if supports_callback?(bridge, :sync_runtime, 2) do
        bridge.sync_runtime(before_config, after_config)
      else
        Bridge.sync_config_runtime(before_config, after_config)
      end
    end
  end

  @doc "Synchronizes runtime from the canonical DB config for provider."
  @spec sync_provider_runtime(atom() | String.t()) :: :ok | {:error, term()}
  def sync_provider_runtime(provider) do
    with {:ok, config} <- Bridge.fetch_any_channel_config(provider),
         {:ok, bridge} <- Bridge.resolve_bridge(provider) do
      Bridge.dispatch_provider_runtime_sync(bridge, config)
    end
  end

  defp supports_callback?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end

  defp default_source_scope(config) do
    %{
      provider: config.provider,
      config_id: config.id,
      scope_id: to_string(config.id),
      label: config.name,
      filters: %{}
    }
  end
end
