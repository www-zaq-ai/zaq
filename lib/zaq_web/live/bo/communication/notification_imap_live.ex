defmodule ZaqWeb.Live.BO.Communication.NotificationImapLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  require Logger

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Router
  alias Zaq.NodeRouter
  alias Zaq.System.ImapConfig
  alias Zaq.Types.EncryptedString
  alias ZaqWeb.ChangesetErrors

  @imap_provider "email:imap"

  @impl true
  def mount(_params, _session, socket) do
    config = current_imap_config()
    changeset = ImapConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/channels/retrieval/email/imap")
     |> assign(:page_title, "IMAP Configuration")
     |> assign(:form, to_form(changeset))
     |> assign(:imap_enabled, config.enabled)
     |> assign(:available_mailboxes, mailbox_options(config.selected_mailboxes, []))
     |> assign(:mailbox_status, :idle)
     |> assign(:save_status, :idle)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_path, "/bo/channels/retrieval/email/imap")}
  end

  @impl true
  def handle_event("validate", %{"imap_config" => params}, socket) do
    config = current_imap_config()

    changeset =
      config
      |> ImapConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(
       :available_mailboxes,
       mailbox_options(
         Ecto.Changeset.get_field(changeset, :selected_mailboxes, []),
         socket.assigns.available_mailboxes
       )
     )
     |> assign(:save_status, :idle)}
  end

  @impl true
  def handle_event("load_mailboxes", _params, socket) do
    config = config_from_changeset(socket.assigns.form.source)

    case validate_mailbox_load_inputs(config) do
      :ok ->
        selected = Ecto.Changeset.get_field(socket.assigns.form.source, :selected_mailboxes, [])
        spawn_mailbox_loader(mailbox_load_params(config), selected)

        {:noreply,
         socket
         |> assign(:mailbox_status, :loading)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:mailbox_status, {:error, message})}
    end
  end

  @impl true
  def handle_event("save", %{"imap_config" => params}, socket) do
    config = current_imap_config()
    changeset = ImapConfig.changeset(config, params)

    case persist_imap_config(changeset) do
      {:ok, _updated_config} ->
        fresh = current_imap_config()
        fresh_changeset = ImapConfig.changeset(fresh, %{})
        sync_result = sync_runtime(@imap_provider)

        {:noreply,
         socket
         |> assign(:imap_enabled, fresh.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(
           :available_mailboxes,
           mailbox_options(fresh.selected_mailboxes, socket.assigns.available_mailboxes)
         )
         |> assign(:save_status, :ok)
         |> maybe_put_runtime_sync_flash(sync_result)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.put(cs, :action, :validate)))
         |> assign(:save_status, {:error, format_changeset_errors(cs)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save IMAP configuration.")
         |> assign(:save_status, {:error, inspect(reason)})}
    end
  end

  @impl true
  def handle_event("activate", _params, socket) do
    config = current_imap_config()
    changeset = ImapConfig.changeset(config, %{"enabled" => to_string(!config.enabled)})

    case persist_imap_config(changeset) do
      {:ok, _updated_config} ->
        fresh = current_imap_config()
        fresh_changeset = ImapConfig.changeset(fresh, %{})
        sync_result = sync_runtime(@imap_provider)

        {:noreply,
         socket
         |> assign(:imap_enabled, fresh.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(
           :available_mailboxes,
           mailbox_options(fresh.selected_mailboxes, socket.assigns.available_mailboxes)
         )
         |> assign(:save_status, :idle)
         |> maybe_put_runtime_sync_flash(sync_result)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(:save_status, {:error, format_changeset_errors(cs)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update IMAP status.")
         |> assign(:save_status, {:error, inspect(reason)})}
    end
  end

  @impl true
  def handle_info({:load_mailboxes_result, config, selected, result}, socket) do
    case result do
      {:ok, mailboxes} ->
        {:noreply,
         socket
         |> assign(:available_mailboxes, mailbox_options(selected, mailboxes))
         |> assign(:mailbox_status, :ok)}

      {:error, reason} ->
        message = format_load_error(reason)

        Logger.error(
          "[NotificationImapLive] mailbox load failed provider=#{@imap_provider} url=#{inspect(map_get(config, :url))} ssl=#{inspect(map_get(config, :ssl))} port=#{inspect(map_get(config, :port))} username=#{inspect(map_get(config, :username))} reason=#{inspect(reason)}"
        )

        {:noreply,
         socket
         |> assign(:mailbox_status, {:error, message})}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset, field_separator: " ")
  end

  defp current_imap_config do
    channel = ChannelConfig.get_any_by_provider(@imap_provider)
    settings = if channel, do: ChannelConfig.imap_settings(channel), else: %{}

    %ImapConfig{
      enabled: if(channel, do: channel.enabled, else: false),
      url: if(channel, do: channel.url, else: nil),
      port: parse_int(map_get(settings, "port"), 993),
      ssl: map_get(settings, "ssl") != false,
      username: map_get(settings, "username"),
      password: decrypt_token(channel),
      selected_mailboxes: selected_mailboxes_string(settings),
      mark_as_read: map_get(settings, "mark_as_read") != false,
      load_initial_unread: map_get(settings, "load_initial_unread") == true,
      ssl_depth: parse_int(map_get(settings, "ssl_depth"), 3),
      poll_interval: parse_int(map_get(settings, "poll_interval"), 30_000),
      idle_timeout: parse_int(map_get(settings, "idle_timeout"), 1_500_000)
    }
  end

  defp persist_imap_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    attrs = %{
      name: "Email IMAP",
      kind: "retrieval",
      url: blank_to_nil(config.url),
      token: blank_to_nil(config.password),
      enabled: config.enabled,
      settings: %{
        "imap" => %{
          "port" => config.port,
          "ssl" => config.ssl,
          "ssl_depth" => config.ssl_depth,
          "username" => blank_to_nil(config.username),
          "selected_mailboxes" => ImapConfig.normalize_mailboxes(config.selected_mailboxes),
          "mark_as_read" => config.mark_as_read,
          "load_initial_unread" => config.load_initial_unread,
          "poll_interval" => config.poll_interval,
          "idle_timeout" => config.idle_timeout
        }
      }
    }

    ChannelConfig.upsert_by_provider(@imap_provider, attrs)
  end

  defp persist_imap_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp selected_mailboxes_string(settings) do
    settings
    |> map_get("selected_mailboxes")
    |> case do
      list when is_list(list) -> list
      _ -> ["INBOX"]
    end
  end

  defp config_from_changeset(changeset) do
    %ImapConfig{
      enabled: Ecto.Changeset.get_field(changeset, :enabled, false),
      url: Ecto.Changeset.get_field(changeset, :url),
      port: Ecto.Changeset.get_field(changeset, :port, 993),
      ssl: Ecto.Changeset.get_field(changeset, :ssl, true),
      username: Ecto.Changeset.get_field(changeset, :username),
      password: Ecto.Changeset.get_field(changeset, :password),
      selected_mailboxes: Ecto.Changeset.get_field(changeset, :selected_mailboxes, ["INBOX"]),
      mark_as_read: Ecto.Changeset.get_field(changeset, :mark_as_read, true),
      load_initial_unread: Ecto.Changeset.get_field(changeset, :load_initial_unread, false),
      ssl_depth: Ecto.Changeset.get_field(changeset, :ssl_depth, 3),
      poll_interval: Ecto.Changeset.get_field(changeset, :poll_interval, 30_000),
      idle_timeout: Ecto.Changeset.get_field(changeset, :idle_timeout, 1_500_000)
    }
  end

  defp mailbox_load_params(%ImapConfig{} = config) do
    %{
      provider: @imap_provider,
      url: config.url,
      token: config.password,
      settings: %{
        "imap" => %{
          "port" => config.port,
          "ssl" => config.ssl,
          "ssl_depth" => config.ssl_depth,
          "username" => config.username,
          "selected_mailboxes" => ImapConfig.normalize_mailboxes(config.selected_mailboxes),
          "mark_as_read" => config.mark_as_read,
          "load_initial_unread" => config.load_initial_unread,
          "poll_interval" => config.poll_interval,
          "idle_timeout" => config.idle_timeout
        }
      }
    }
  end

  defp spawn_mailbox_loader(config, selected) do
    caller = self()

    Task.start(fn ->
      result =
        try do
          NodeRouter.call(:channels, router_module(), :list_mailboxes, [@imap_provider, config])
        rescue
          error -> {:error, {:mailbox_load_failed, Exception.message(error)}}
        catch
          :exit, reason -> {:error, {:mailbox_load_failed, reason}}
        end

      send(caller, {:load_mailboxes_result, config, selected, result})
    end)
  end

  defp sync_runtime(provider) do
    NodeRouter.call(:channels, router_module(), :sync_provider_runtime, [provider])
  end

  defp maybe_put_runtime_sync_flash(socket, :ok), do: socket
  defp maybe_put_runtime_sync_flash(socket, nil), do: socket

  defp maybe_put_runtime_sync_flash(socket, {:error, reason}) do
    put_flash(socket, :error, "IMAP runtime sync failed: #{inspect(reason)}")
  end

  defp mailbox_options(selected, available) do
    (List.wrap(selected) ++ List.wrap(available))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validate_mailbox_load_inputs(%ImapConfig{} = cfg) do
    cond do
      blank?(cfg.url) -> {:error, "IMAP URL is required before loading mailboxes."}
      blank?(cfg.username) -> {:error, "IMAP username is required before loading mailboxes."}
      blank?(cfg.password) -> {:error, "IMAP password is required before loading mailboxes."}
      true -> :ok
    end
  end

  defp format_load_error({:list_mailboxes_failed, reason}),
    do: "Unable to load mailboxes from IMAP server. #{format_reason(reason)}"

  defp format_load_error({:connect_failed, reason}),
    do: "Unable to connect to IMAP server. #{format_reason(reason)}"

  defp format_load_error(reason),
    do: "Connection failed while loading IMAP mailboxes. #{format_reason(reason)}"

  defp format_reason(:auth_failed), do: "Authentication failed. Check username/password."
  defp format_reason(:econnrefused), do: "Connection refused. Check URL and port."
  defp format_reason(:timeout), do: "Connection timed out."
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp decrypt_token(nil), do: nil

  defp decrypt_token(%ChannelConfig{token: token}) do
    case EncryptedString.decrypt(token) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    keys = [key, Atom.to_string(key)]

    case fetch_first(map, keys) do
      {:ok, value} -> value
      :error -> fetch_from_imap_settings(map, keys)
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    keys = [key, atom_key_for_string(map, key)]

    case fetch_first(map, keys) do
      {:ok, value} -> value
      :error -> fetch_from_imap_settings(map, keys)
    end
  end

  defp map_get(_map, _key), do: nil

  defp fetch_from_imap_settings(map, keys) do
    with imap when is_map(imap) <- imap_settings_map(map),
         {:ok, value} <- fetch_first(imap, keys) do
      value
    else
      _ -> nil
    end
  end

  defp imap_settings_map(map) do
    settings = Map.get(map, :settings) || Map.get(map, "settings")

    case settings do
      settings when is_map(settings) ->
        case Map.get(settings, :imap) || Map.get(settings, "imap") do
          imap when is_map(imap) -> imap
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_first(map, keys) do
    Enum.reduce_while(keys, :error, fn
      nil, _acc ->
        {:cont, :error}

      lookup_key, _acc ->
        case Map.fetch(map, lookup_key) do
          {:ok, _value} = hit -> {:halt, hit}
          :error -> {:cont, :error}
        end
    end)
  end

  defp atom_key_for_string(map, key) do
    Enum.find_value(map, fn
      {lookup_key, _value} when is_atom(lookup_key) ->
        if Atom.to_string(lookup_key) == key, do: lookup_key

      _ ->
        nil
    end)
  end

  defp router_module,
    do: Application.get_env(:zaq, :notification_imap_router_module, Router)
end
