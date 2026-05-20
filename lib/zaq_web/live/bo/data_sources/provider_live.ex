defmodule ZaqWeb.Live.BO.DataSources.ProviderLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  import Ecto.Query

  alias Zaq.Channels.{Bridge, ChannelConfig, DataSourceBridge}
  alias Zaq.Channels.ProviderCatalog
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.Communication.ChannelConfigPersistence
  alias ZaqWeb.Live.BO.Communication.OAuthClaimState
  alias ZaqWeb.Live.BO.Communication.OAuthPopupUI
  require Logger

  @max_pages_default 5

  @impl true
  def mount(%{"provider" => provider}, _session, socket) do
    label = ProviderCatalog.label(provider)

    configs = if socket.assigns.service_available, do: list_configs(provider), else: []
    grants = grants_by_config(configs)
    root_folders = seed_root_folders_by_config(configs)
    root_folder_meta = seed_root_folder_meta_by_config(configs)
    stats_errors = seed_stats_errors_by_config(configs)
    capabilities = capability_snapshot(provider)

    {:ok,
     socket
     |> assign(:current_path, ~p"/bo/channels/data_source")
     |> assign(:page_title, label)
     |> assign(:provider, provider)
     |> assign(:provider_label, label)
     |> assign(:configs, configs)
     |> assign(:grants_by_config, grants)
     |> assign(:root_folders_by_config, root_folders)
     |> assign(:root_folder_meta_by_config, root_folder_meta)
     |> assign(:stats_errors_by_config, stats_errors)
     |> assign(:capabilities_snapshot, capabilities)
     |> assign(:native_export_options, export_options_for_provider(provider))
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
     |> assign(:form, nil)
     |> assign(:modal_errors, [])
     |> assign(:connect_credentials, connect_credentials_for(provider))
     |> assign(:credential_modal, false)
     |> assign(:credential_changeset, nil)
     |> assign(:credential_form, nil)
     |> assign(:credential_errors, [])
     |> assign(:global_settings_path, ~p"/bo/system-config?tab=global")
     |> assign(:confirm_delete, nil)
     |> assign(:capability_modal_open, false)
     |> assign(:folder_info_modal, nil)
     |> assign(:oauth_claim_modal, false)
     |> assign(:oauth_claim_url, nil)}
  end

  def handle_event("open_new_credential", _params, socket) do
    changeset =
      engine_connect_change_credential(%Credential{}, %{
        "provider" => credential_provider_for(socket.assigns.provider),
        "request_format" => credential_request_format_for(socket.assigns.provider),
        "auth_kind" => "oauth2",
        "user_level" => false,
        "metadata" => %{}
      })

    case ensure_global_base_url_for_oauth2("oauth2") do
      :ok ->
        {:noreply,
         socket
         |> assign(:credential_modal, true)
         |> assign(:credential_changeset, changeset)
         |> assign(:credential_form, to_form(changeset, as: :credential))
         |> assign(:credential_errors, [])}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:credential_modal, true)
         |> assign(:credential_changeset, changeset)
         |> assign(:credential_form, to_form(changeset, as: :credential))
         |> assign(:credential_errors, [message])}
    end
  end

  def handle_event("close_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:credential_modal, false)
     |> assign(:credential_changeset, nil)
     |> assign(:credential_form, nil)
     |> assign(:credential_errors, [])}
  end

  def handle_event("validate_credential", %{"credential" => params}, socket) do
    changeset =
      %Credential{}
      |> engine_connect_change_credential(
        credential_params_for_create(params, socket.assigns.provider)
      )
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:credential_changeset, changeset)
     |> assign(:credential_form, to_form(changeset, as: :credential))
     |> assign(:credential_errors, format_errors(changeset))}
  end

  def handle_event("save_credential", %{"credential" => params}, socket) do
    params = credential_params_for_create(params, socket.assigns.provider)

    with :ok <- ensure_global_base_url_for_oauth2(Map.get(params, "auth_kind", "oauth2")),
         {:ok, credential} <- engine_connect_create_credential(params) do
      connect_settings =
        socket.assigns.changeset
        |> Ecto.Changeset.get_field(:settings, %{})
        |> put_connect_credential_id(credential.id)

      config_changeset =
        socket.assigns.changeset
        |> Ecto.Changeset.put_change(:settings, connect_settings)

      {:noreply,
       socket
       |> assign(:credential_modal, false)
       |> assign(:credential_changeset, nil)
       |> assign(:credential_form, nil)
       |> assign(:credential_errors, [])
       |> assign(:connect_credentials, connect_credentials_for(socket.assigns.provider))
       |> assign(:changeset, config_changeset)
       |> assign(:form, to_form(config_changeset, as: :form))
       |> put_flash(:info, "Credential created.")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :credential_errors, [message])}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:credential_changeset, changeset)
         |> assign(:credential_form, to_form(changeset, as: :credential))
         |> assign(:credential_errors, format_errors(changeset))}
    end
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{service_available: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("open_modal", %{"action" => "new"}, socket) do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        "provider" => socket.assigns.provider,
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{
          "connect" => %{
            "root_selector" => root_folder_default(socket.assigns.provider),
            "max_pages" => @max_pages_default
          }
        }
      })

    {:noreply,
     socket
     |> assign(:modal, :new)
     |> assign(:native_export_options, export_options_for_provider(socket.assigns.provider))
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset, as: :form))
     |> assign(:modal_errors, [])}
  end

  def handle_event("open_modal", %{"action" => "edit", "id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)
    changeset = ChannelConfig.changeset(config, %{})

    {:noreply,
     socket
     |> assign(:modal, :edit)
     |> assign(
       :native_export_options,
       export_options_for_provider(socket.assigns.provider, config.id)
     )
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset, as: :form))
     |> assign(:modal_errors, [])}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
     |> assign(:form, nil)
     |> assign(:modal_errors, [])
     |> assign(:native_export_options, export_options_for_provider(socket.assigns.provider))
     |> assign(:oauth_claim_modal, false)
     |> assign(:oauth_claim_url, nil)}
  end

  def handle_event("open_oauth_claim", %{"url" => url}, socket) when is_binary(url) do
    {:noreply, OAuthPopupUI.open(socket, url)}
  end

  def handle_event("close_oauth_claim", _params, socket) do
    {:noreply, OAuthPopupUI.close(socket)}
  end

  def handle_event("oauth_popup_result", _params, socket) do
    {:noreply, socket |> OAuthPopupUI.close() |> put_flash(:info, "OAuth2 grant flow completed.")}
  end

  def handle_event("oauth_popup_blocked", _params, socket) do
    {:noreply, OAuthPopupUI.blocked(socket)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    changeset =
      socket.assigns.changeset.data
      |> ChannelConfig.changeset(params)
      |> maybe_validate_connect_credential_provider(socket.assigns.provider)
      |> maybe_validate_global_base_url_for_webhook_capability(socket.assigns.provider)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset, as: :form))
     |> assign(:modal_errors, format_errors(changeset))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    previous_config =
      if socket.assigns.modal == :edit, do: socket.assigns.changeset.data, else: nil

    result =
      ChannelConfigPersistence.persist(
        socket.assigns.modal,
        socket.assigns.changeset.data,
        params,
        socket.assigns.provider,
        &validate_channel_config/2
      )

    case result do
      {:ok, config} ->
        _sync = sync_channel_runtime(previous_config, config)
        {:noreply, refresh_provider_page(socket, "Data source config saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> assign(:form, to_form(changeset, as: :form))
         |> assign(:modal_errors, format_errors(changeset))}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    previous_config = Repo.get!(ChannelConfig, id)

    config =
      previous_config
      |> Ecto.Changeset.change(enabled: !previous_config.enabled)
      |> Repo.update!()

    _sync = sync_channel_runtime(previous_config, config)

    {:noreply,
     refresh_provider_page_without_folder_listing(
       socket,
       "#{config.name} #{if previous_config.enabled, do: "disabled", else: "enabled"}."
     )}
  end

  def handle_event("open_test", %{"id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)

    root_selector = root_selector_for_config(config, socket.assigns.provider)
    max_pages = max_pages_for_config(config)

    {folders, error, meta} =
      root_folders_for_provider(socket.assigns.provider, config.id, root_selector,
        max_pages: max_pages
      )

    {:noreply,
     socket
     |> assign(
       :root_folders_by_config,
       Map.put(socket.assigns.root_folders_by_config, config.id, folders)
     )
     |> assign(
       :stats_errors_by_config,
       Map.put(socket.assigns.stats_errors_by_config, config.id, error)
     )
     |> assign(
       :root_folder_meta_by_config,
       Map.put(socket.assigns.root_folder_meta_by_config, config.id, meta)
     )
     |> put_flash(
       :info,
       "#{config.name} refreshed: #{meta.scanned_entries} items scanned, #{meta.matched_folders} root folders matched (#{meta.pages_loaded} pages loaded)."
     )}
  end

  def handle_event("fetch_more", %{"id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)
    root_selector = root_selector_for_config(config, socket.assigns.provider)
    max_pages = max_pages_for_config(config)

    previous_folders = Map.get(socket.assigns.root_folders_by_config, config.id, [])
    previous_meta = Map.get(socket.assigns.root_folder_meta_by_config, config.id, %{})

    case Map.get(previous_meta, :next_page_token) do
      token when is_binary(token) and token != "" ->
        {new_folders, error, new_meta} =
          root_folders_for_provider(socket.assigns.provider, config.id, root_selector,
            max_pages: max_pages,
            page_token: token
          )

        merged_folders =
          merge_records(root_folders(previous_folders), root_folders(new_folders))

        merged_meta = %{
          pages_loaded:
            Map.get(previous_meta, :pages_loaded, 0) + Map.get(new_meta, :pages_loaded, 0),
          scanned_entries:
            Map.get(previous_meta, :scanned_entries, 0) + Map.get(new_meta, :scanned_entries, 0),
          matched_folders: length(merged_folders),
          has_more?: Map.get(new_meta, :has_more?, false),
          next_page_token: Map.get(new_meta, :next_page_token),
          truncated: Map.get(new_meta, :has_more?, false),
          max_pages_per_batch: max_pages
        }

        {:noreply,
         socket
         |> assign(
           :root_folders_by_config,
           Map.put(socket.assigns.root_folders_by_config, config.id, merged_folders)
         )
         |> assign(
           :stats_errors_by_config,
           Map.put(socket.assigns.stats_errors_by_config, config.id, error)
         )
         |> assign(
           :root_folder_meta_by_config,
           Map.put(socket.assigns.root_folder_meta_by_config, config.id, merged_meta)
         )
         |> put_flash(
           :info,
           "#{config.name}: loaded #{Map.get(new_meta, :pages_loaded, 0)} more pages (#{Map.get(new_meta, :scanned_entries, 0)} items scanned)."
         )}

      _ ->
        {:noreply, socket |> put_flash(:info, "No more pages to fetch for #{config.name}.")}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete, id)}
  end

  def handle_event("open_capabilities", _params, socket) do
    {:noreply, assign(socket, :capability_modal_open, true)}
  end

  def handle_event("close_capabilities", _params, socket) do
    {:noreply, assign(socket, :capability_modal_open, false)}
  end

  def handle_event(
        "open_folder_info",
        %{"config-id" => config_id, "folder-id" => folder_id},
        socket
      ) do
    folders =
      socket.assigns.root_folders_by_config
      |> Map.get(parse_int(config_id), [])
      |> root_folders()

    folder = Enum.find(folders, fn record -> to_string(record.id) == to_string(folder_id) end)

    {:noreply,
     assign(socket, :folder_info_modal, %{config_id: parse_int(config_id), folder: folder})}
  end

  def handle_event("close_folder_info", _params, socket) do
    {:noreply, assign(socket, :folder_info_modal, nil)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("delete", _params, socket) do
    id = socket.assigns.confirm_delete

    case Repo.get(ChannelConfig, id) do
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Config not found.")}

      config ->
        Repo.delete!(config)

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> refresh_provider_page("Data source config deleted.")}
    end
  end

  def active_grant_for_config(config, grants_by_config),
    do: Map.get(grants_by_config || %{}, config.id)

  def capabilities_modal_open?(current, _config_id) when is_boolean(current), do: current

  def capabilities_modal_open?(current_id, config_id) do
    to_string(current_id || "") == to_string(config_id)
  end

  def capabilities_for_modal(config, capabilities_by_config) do
    snapshot = Map.get(capabilities_by_config, config.id, %{})
    labels = Map.get(snapshot, :labels, %{})
    required = Map.get(snapshot, :required, [])
    resolved = Map.get(snapshot, :resolved, %{})

    required
    |> Enum.map(fn capability ->
      %{
        label: Map.get(labels, capability, capability) |> to_string(),
        supported?:
          Map.has_key?(resolved, capability) or Map.has_key?(resolved, to_string(capability))
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.label))
  end

  def selected_config(configs, id) do
    Enum.find(configs, fn config -> to_string(config.id) == to_string(id || "") end)
  end

  def root_folders(nil), do: []
  def root_folders(value) when is_list(value), do: value
  def root_folders(_), do: []

  def folder_name(%{name: name, id: id}) do
    cond do
      is_binary(name) and String.trim(name) != "" -> name
      is_binary(id) and String.trim(id) != "" -> id
      true -> "Unnamed"
    end
  end

  def folder_icon(%{icon: icon}) when is_binary(icon), do: icon
  def folder_icon(_), do: nil

  def folder_url(%{url: url}) when is_binary(url), do: url
  def folder_url(_), do: nil

  def selected_folder_info(folder_info_modal), do: folder_info_modal && folder_info_modal.folder

  def folder_permissions(%{permissions: permissions}) when is_list(permissions), do: permissions
  def folder_permissions(_), do: []

  def permission_label(%{name: name}) when is_binary(name) and name != "", do: name

  def permission_label(%{id: id}) when is_binary(id) and id != "", do: id
  def permission_label(_), do: "Unknown permission"

  def connect_credential_id_from_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_field(:settings, %{})
    |> Map.get("connect", %{})
    |> Map.get("credential_id", "")
  end

  def root_selector_from_changeset(%Ecto.Changeset{} = changeset, provider) do
    settings = Ecto.Changeset.get_field(changeset, :settings, %{})

    settings
    |> Map.get("connect", %{})
    |> Map.get("root_selector")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> root_folder_default(provider)
    end
  end

  def selected_export_mime_from_changeset(%Ecto.Changeset{} = changeset, native_mime_type) do
    changeset
    |> Ecto.Changeset.get_field(:settings, %{})
    |> Map.get("connect", %{})
    |> Map.get("export_defaults_by_native_mime", %{})
    |> Map.get(native_mime_type)
    |> case do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  def oauth_claim_state_for_changeset(%Ecto.Changeset{} = changeset) do
    OAuthClaimState.for_changeset(changeset)
  end

  def oauth_claim_state_for_changeset(_), do: OAuthClaimState.for_changeset(nil)

  defp list_configs(provider) do
    ChannelConfig
    |> where([c], c.provider == ^provider and c.kind == "data_source")
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp grants_by_config(configs) do
    config_ids = Enum.map(configs, &to_string(&1.id))

    engine_connect_list_grants(%{resource_type: "data_source", status: "active"})
    |> Enum.filter(&(&1.resource_id in config_ids))
    |> Enum.group_by(&String.to_integer(&1.resource_id))
    |> Map.new(fn {config_id, grants} -> {config_id, Enum.max_by(grants, & &1.id)} end)
  end

  defp seed_root_folders_by_config(configs), do: Map.new(configs, &{&1.id, nil})

  defp seed_root_folder_meta_by_config(configs), do: Map.new(configs, &{&1.id, %{}})

  defp seed_stats_errors_by_config(configs), do: Map.new(configs, &{&1.id, nil})

  defp root_folders_for_provider(provider, config_id, root_selector, opts) do
    max_pages = Keyword.get(opts, :max_pages, @max_pages_default)
    start_page_token = Keyword.get(opts, :page_token)

    filters = datasource_list_filters(root_selector)

    do_list_root_folders(provider, config_id, filters, root_selector, max_pages, start_page_token)
  end

  defp do_list_root_folders(
         provider,
         config_id,
         filters,
         root_selector,
         max_pages,
         start_page_token
       ) do
    base_params = %{
      "config_id" => config_id,
      "root_selector" => root_selector,
      "filters" => filters,
      "include_permissions" => true
    }

    Enum.reduce_while(1..max_pages, {[], start_page_token, 0, 0}, fn _page_index, state ->
      {acc_folders, token, pages_loaded, scanned_entries} = state

      params = with_page_token(base_params, token)

      handle_root_folder_page_response(
        dispatch_list_files(provider, params),
        provider,
        config_id,
        root_selector,
        acc_folders,
        pages_loaded,
        scanned_entries
      )
    end)
    |> case do
      {:error, reason, acc_folders, pages_loaded, scanned_entries} ->
        meta = errored_root_folder_meta(acc_folders, pages_loaded, scanned_entries, max_pages)

        {dedupe_and_sort_records(acc_folders), format_stats_error(reason), meta}

      {:unknown_error, acc_folders, pages_loaded, scanned_entries} ->
        meta = errored_root_folder_meta(acc_folders, pages_loaded, scanned_entries, max_pages)

        {dedupe_and_sort_records(acc_folders),
         %{message: "Unknown provider error while fetching root folders."}, meta}

      {acc_folders, next_token, pages_loaded, scanned_entries} ->
        folders = dedupe_and_sort_records(acc_folders)

        meta = %{
          pages_loaded: pages_loaded,
          scanned_entries: scanned_entries,
          matched_folders: length(folders),
          has_more?: is_binary(next_token) and next_token != "",
          next_page_token: next_token,
          truncated: is_binary(next_token) and next_token != "",
          max_pages_per_batch: max_pages
        }

        {folders, nil, meta}
    end
  end

  defp with_page_token(base_params, token) when is_binary(token) and token != "",
    do: Map.put(base_params, "page_token", token)

  defp with_page_token(base_params, _token), do: Map.delete(base_params, "page_token")

  defp maybe_continue_root_folder_listing(state, next_token)
       when is_binary(next_token) and next_token != "",
       do: {:cont, state}

  defp maybe_continue_root_folder_listing(state, _next_token), do: {:halt, state}

  defp handle_root_folder_page_response(
         {:ok, %Zaq.Contracts.RecordPage{} = page},
         _provider,
         _config_id,
         root_selector,
         acc_folders,
         pages_loaded,
         scanned_entries
       ) do
    records = page.records || []
    folders = normalize_root_folders_from_records(records, root_selector)
    next_token = get_in(page.pagination, [:cursor])

    next_state =
      {acc_folders ++ folders, next_token, pages_loaded + 1, scanned_entries + length(records)}

    maybe_continue_root_folder_listing(next_state, next_token)
  end

  defp handle_root_folder_page_response(
         {:error, reason},
         provider,
         config_id,
         _root_selector,
         acc_folders,
         pages_loaded,
         scanned_entries
       ) do
    Logger.warning(
      "datasource root_folder fetch failed provider=#{provider} config_id=#{config_id}: #{inspect(reason)}"
    )

    {:halt, {:error, reason, acc_folders, pages_loaded, scanned_entries}}
  end

  defp handle_root_folder_page_response(
         _unknown,
         provider,
         config_id,
         _root_selector,
         acc_folders,
         pages_loaded,
         scanned_entries
       ) do
    Logger.warning(
      "datasource root_folder fetch failed provider=#{provider} config_id=#{config_id}: unknown response"
    )

    {:halt, {:unknown_error, acc_folders, pages_loaded, scanned_entries}}
  end

  defp errored_root_folder_meta(acc_folders, pages_loaded, scanned_entries, max_pages) do
    %{
      pages_loaded: pages_loaded,
      scanned_entries: scanned_entries,
      matched_folders: length(Enum.uniq_by(acc_folders, &record_key/1)),
      has_more?: false,
      next_page_token: nil,
      truncated: false,
      max_pages_per_batch: max_pages
    }
  end

  defp normalize_root_folders_from_records(records, _root_selector) when is_list(records) do
    records
    |> Enum.filter(&match?(%Zaq.Contracts.Record{}, &1))
  end

  defp normalize_root_folders_from_records(_, _), do: []

  defp merge_records(left, right), do: dedupe_and_sort_records(left ++ right)

  defp dedupe_and_sort_records(records) do
    records
    |> Enum.uniq_by(&record_key/1)
    |> Enum.sort_by(&String.downcase(folder_name(&1)))
  end

  defp record_key(%{id: id}) when is_binary(id), do: id
  defp record_key(record), do: inspect(record)

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> -1
    end
  end

  defp parse_int(_), do: -1

  defp format_stats_error(%{message: message} = err) when is_binary(message) do
    %{
      message: Map.get(err, :display_message) || Map.get(err, "display_message") || message,
      code: Map.get(err, :code),
      provider: Map.get(err, :provider),
      status: Map.get(err, :status)
    }
  end

  defp format_stats_error(nil), do: nil

  defp format_stats_error(reason),
    do: %{message: inspect(reason), code: nil, provider: nil, status: nil}

  defp capability_snapshot(provider) do
    case dispatch_channel_capability_snapshot(provider) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp dispatch_list_files(provider, params) do
    event =
      Event.new(
        %{provider: provider, params: params},
        :channels,
        opts: [action: :data_source_list_files]
      )

    NodeRouter.dispatch(event).response
  end

  defp dispatch_export_options(provider, params) do
    event =
      Event.new(
        %{provider: provider, params: params},
        :channels,
        opts: [action: :data_source_export_options]
      )

    NodeRouter.dispatch(event).response
  end

  defp export_options_for_provider(provider, config_id \\ nil) do
    params = if is_nil(config_id), do: %{}, else: %{"config_id" => config_id}

    case dispatch_export_options(provider, params) do
      {:ok, %{} = payload} ->
        payload
        |> Map.get(
          :export_formats_by_native_type,
          Map.get(payload, "export_formats_by_native_type", %{})
        )
        |> DataSourceBridge.normalize_export_formats_map()

      _ ->
        %{}
    end
  end

  defp connect_credentials_for(provider) do
    expected_provider = credential_provider_for(provider)

    engine_connect_list_credentials()
    |> Enum.filter(&(&1.provider == expected_provider))
  end

  defp credential_provider_for(provider),
    do: ProviderCatalog.credential_provider(to_string(provider))

  defp credential_request_format_for(provider),
    do: ProviderCatalog.credential_request_format(to_string(provider))

  defp credential_params_for_create(params, provider) do
    params
    |> Map.put("provider", credential_provider_for(provider))
    |> Map.put("request_format", credential_request_format_for(provider))
    |> Map.put_new("user_level", false)
    |> Map.put_new("metadata", %{})
  end

  defp put_connect_credential_id(settings, credential_id) when is_map(settings) do
    connect =
      settings
      |> Map.get("connect", %{})
      |> Map.put("credential_id", to_string(credential_id))

    Map.put(settings, "connect", connect)
  end

  defp datasource_list_filters(root_selector) do
    %{
      "kind" => "folder",
      "parent" => root_selector,
      "trashed" => false
    }
  end

  defp root_folder_default(provider), do: ProviderCatalog.root_folder_default(to_string(provider))

  defp root_selector_for_config(config, provider) do
    config
    |> Map.get(:settings, %{})
    |> Map.get("connect", %{})
    |> Map.get("root_selector")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> root_folder_default(provider)
    end
  end

  defp max_pages_for_config(config) do
    raw =
      config
      |> Map.get(:settings, %{})
      |> Map.get("connect", %{})
      |> Map.get("max_pages")

    ParseUtils.parse_positive_int(raw, @max_pages_default)
  end

  defp maybe_validate_connect_credential_provider(changeset, provider) do
    settings = Ecto.Changeset.get_field(changeset, :settings, %{})

    credential_id =
      settings
      |> Map.get("connect", %{})
      |> Map.get("credential_id")

    expected_provider = credential_provider_for(provider)

    case credential_id do
      id when id in [nil, ""] ->
        changeset

      _ ->
        case engine_connect_fetch_credential(credential_id) do
          {:ok, credential} when credential.provider == expected_provider ->
            changeset

          {:ok, _credential} ->
            Ecto.Changeset.add_error(
              changeset,
              :settings,
              "Selected credential provider does not match this data source."
            )

          {:error, :not_found} ->
            Ecto.Changeset.add_error(changeset, :settings, "Selected credential was not found.")
        end
    end
  end

  defp validate_channel_config(changeset, provider) do
    changeset
    |> maybe_validate_connect_credential_provider(provider)
    |> maybe_validate_global_base_url_for_webhook_capability(provider)
  end

  defp maybe_validate_global_base_url_for_webhook_capability(changeset, provider) do
    if provider_requires_global_base_url?(provider) and is_nil(Zaq.System.get_global_base_url()) do
      Ecto.Changeset.add_error(
        changeset,
        :settings,
        "Global base URL is required for webhook/watch capable providers. Configure it in System Configuration > Global."
      )
    else
      changeset
    end
  end

  defp provider_requires_global_base_url?(provider) do
    case Bridge.capability_snapshot(provider) do
      {:ok, %{resolved: resolved}} when is_map(resolved) ->
        webhook_capability_declared?(resolved)

      _ ->
        false
    end
  end

  defp webhook_capability_declared?(resolved) do
    Enum.any?(
      [
        :watch_changes_webhook,
        :receive_change_webhook,
        "watch_changes_webhook",
        "receive_change_webhook"
      ],
      fn key ->
        match?(value when not is_nil(value), Map.get(resolved, key))
      end
    )
  end

  defp ensure_global_base_url_for_oauth2("oauth2") do
    if is_nil(Zaq.System.get_global_base_url()) do
      {:error,
       "Global base URL is required before creating an OAuth2 credential. Configure it in Global settings."}
    else
      :ok
    end
  end

  defp ensure_global_base_url_for_oauth2(_), do: :ok

  defp format_errors(%Ecto.Changeset{} = changeset) do
    ChangesetErrors.format(changeset,
      join: false,
      humanize_fields: true,
      field_separator: " "
    )
  end

  defp sync_channel_runtime(before_config, after_config) do
    event =
      Event.new(
        %{before_config: before_config, after_config: after_config},
        :channels,
        opts: [action: :sync_data_source_runtime]
      )

    NodeRouter.dispatch(event).response
  end

  defp dispatch_engine(action, request \\ %{}) do
    Event.new(request, :engine, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp engine_connect_fetch_credential(id),
    do: dispatch_engine(:connect_fetch_credential, %{credential_id: id})

  defp engine_connect_list_credentials,
    do: dispatch_engine(:connect_list_credentials)

  defp engine_connect_list_grants(filters) when is_map(filters),
    do: dispatch_engine(:connect_list_grants, %{filters: filters})

  defp engine_connect_change_credential(credential, attrs),
    do: dispatch_engine(:connect_change_credential, %{credential: credential, attrs: attrs})

  defp engine_connect_create_credential(attrs),
    do: dispatch_engine(:connect_create_credential, %{attrs: attrs})

  defp refresh_provider_page(socket, message) do
    configs = list_configs(socket.assigns.provider)

    root_folders = retain_config_keys(socket.assigns.root_folders_by_config || %{}, configs, nil)

    root_meta = retain_config_keys(socket.assigns.root_folder_meta_by_config || %{}, configs, %{})

    stats_errors = retain_config_keys(socket.assigns.stats_errors_by_config || %{}, configs, nil)

    socket
    |> assign_provider_refresh_base(configs)
    |> assign(:grants_by_config, grants_by_config(configs))
    |> assign(:root_folders_by_config, root_folders)
    |> assign(:root_folder_meta_by_config, root_meta)
    |> assign(:stats_errors_by_config, stats_errors)
    |> assign(:capabilities_snapshot, capability_snapshot(socket.assigns.provider))
    |> put_flash(:info, message)
  end

  defp retain_config_keys(existing_map, configs, default) do
    config_ids = MapSet.new(Enum.map(configs, & &1.id))

    from_existing =
      existing_map
      |> Enum.filter(fn {id, _} -> MapSet.member?(config_ids, id) end)
      |> Map.new()

    Enum.reduce(configs, from_existing, fn config, acc ->
      Map.put_new(acc, config.id, default)
    end)
  end

  defp refresh_provider_page_without_folder_listing(socket, message) do
    configs = list_configs(socket.assigns.provider)

    socket
    |> assign_provider_refresh_base(configs)
    |> assign(:grants_by_config, grants_by_config(configs))
    |> assign(:capabilities_snapshot, capability_snapshot(socket.assigns.provider))
    |> put_flash(:info, message)
  end

  defp assign_provider_refresh_base(socket, configs) do
    socket
    |> assign(:modal, nil)
    |> assign(:confirm_delete, nil)
    |> assign(:capability_modal_open, false)
    |> assign(:changeset, nil)
    |> assign(:form, nil)
    |> assign(:modal_errors, [])
    |> assign(:configs, configs)
  end

  defp dispatch_channel_capability_snapshot(provider) do
    event =
      Event.new(%{provider: provider}, :channels, opts: [action: :channel_capability_snapshot])

    NodeRouter.dispatch(event).response
  end
end
