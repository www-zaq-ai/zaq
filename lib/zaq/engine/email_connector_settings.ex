defmodule Zaq.Engine.EmailConnectorSettings do
  @moduledoc """
  Engine-owned read and persistence boundary for IMAP and SMTP BO settings.

  Connector IDs are always reloaded and checked against their exact provider,
  kind, and archive state. Secrets are processed by the existing encrypted
  schema contracts. Runtime synchronization happens after persistence and is
  dispatched confidentially to Channels with the exact resolved configuration.
  Runtime failure is a warning, never a false database rollback. Channels does
  not reload the connector or authorize the BO actor in this runtime path.
  """

  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.ConnectorConfig.ImapSettings, as: ImapConfigHelpers
  alias Zaq.ConnectorConfig.SmtpSettings, as: SmtpHelpers
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.System.{EmailConfig, ImapConfig}
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils

  @imap_provider "email:imap"
  @smtp_provider "email:smtp"
  @providers [@imap_provider, @smtp_provider]

  @doc "Loads one authoritative connector selection snapshot."
  def snapshot(provider, selected_id \\ nil)

  def snapshot(provider, selected_id) when provider in @providers do
    configs = ChannelConfig.list_by_provider(provider)
    selected_id = normalize_selection(selected_id, configs)

    with {:ok, selected} <- snapshot_selected(provider, selected_id) do
      form_channel =
        selected ||
          %ChannelConfig{provider: provider, kind: "retrieval", enabled: false, settings: %{}}

      {:ok,
       %{
         provider: provider,
         configs: configs,
         selected_config_id: selected_id,
         selected: selected,
         form_config: form_config(provider, form_channel),
         smtp_configs:
           if(provider == @imap_provider,
             do: ChannelConfig.list_by_provider(@smtp_provider),
             else: []
           )
       }}
    end
  end

  def snapshot(_provider, _selected_id), do: {:error, :unsupported_provider}

  @doc "Persists one exact connector and reports post-save runtime state."
  def save(%{provider: provider, selected_config_id: selected_id, params: params}, opts)
      when provider in @providers and is_map(params) and is_list(opts) do
    with {:ok, channel} <- selected_config(provider, selected_id),
         {:ok, saved} <- persist(provider, channel, params),
         runtime <- sync_runtime(saved, opts),
         {:ok, snapshot} <- snapshot(provider, saved.id) do
      {:ok, %{selected_config_id: saved.id, snapshot: snapshot, runtime: runtime}}
    end
  end

  def save(_request, _opts), do: {:error, :invalid_request}

  @doc "Designates an exact live SMTP connector as the notification default."
  def set_default_smtp(id) do
    with {:ok, id} <- cast_id(id),
         {:ok, _config} <- ChannelConfig.resolve_by_provider(@smtp_provider, id),
         {:ok, _} <- ChannelConfig.set_default_smtp_connector(id) do
      snapshot(@smtp_provider, id)
    else
      _ -> {:error, :invalid_smtp_connector}
    end
  end

  defp persist(@smtp_provider, channel, params) do
    config = form_config(@smtp_provider, channel)
    changeset = EmailConfig.changeset(config, params)

    if changeset.valid? do
      value = Ecto.Changeset.apply_changes(changeset)

      with {:ok, password} <- encrypt_password(value.password) do
        attrs = %{
          name: Map.get(params, "connector_name", channel.name || "Email SMTP"),
          kind: "retrieval",
          url: "smtp://configured-in-settings",
          token: "__smtp_unused__",
          enabled: value.enabled,
          settings: %{
            "relay" => value.relay,
            "port" => to_string(value.port || 587),
            "transport_mode" => value.transport_mode,
            "tls" => value.tls,
            "tls_verify" => value.tls_verify,
            "ca_cert_path" => blank_to_nil(value.ca_cert_path),
            "username" => blank_to_nil(value.username),
            "password" => password,
            "from_email" => value.from_email,
            "from_name" => value.from_name
          }
        }

        channel |> ChannelConfig.changeset(attrs) |> Zaq.Repo.insert_or_update()
      end
    else
      {:error, changeset}
    end
  end

  defp persist(@imap_provider, channel, params) do
    config = form_config(@imap_provider, channel)
    changeset = ImapConfig.changeset(config, params)

    if changeset.valid? do
      value = Ecto.Changeset.apply_changes(changeset)
      existing_settings = channel.settings || %{}

      attrs = %{
        name: Map.get(params, "connector_name", channel.name || "Email IMAP"),
        kind: "retrieval",
        url: blank_to_nil(value.url),
        token: blank_to_nil(value.password),
        enabled: value.enabled,
        settings:
          existing_settings
          |> Map.put("imap", %{
            "port" => value.port,
            "ssl" => value.ssl,
            "ssl_depth" => value.ssl_depth,
            "username" => blank_to_nil(value.username),
            "selected_mailboxes" => ImapConfig.normalize_mailboxes(value.selected_mailboxes),
            "mark_as_read" => value.mark_as_read,
            "load_initial_unread" => value.load_initial_unread,
            "poll_interval" => value.poll_interval,
            "idle_timeout" => value.idle_timeout,
            "smtp_config_id" => smtp_config_id(params, channel, value.enabled)
          })
      }

      with {:ok, smtp_id} <- attrs.settings["imap"]["smtp_config_id"] do
        attrs = put_in(attrs, [:settings, "imap", "smtp_config_id"], smtp_id)
        channel |> ChannelConfig.changeset(attrs) |> Zaq.Repo.insert_or_update()
      end
    else
      {:error, changeset}
    end
  end

  defp selected_config(provider, :new),
    do:
      {:ok, %ChannelConfig{provider: provider, kind: "retrieval", enabled: false, settings: %{}}}

  defp selected_config(_provider, nil), do: {:error, :selection_required}

  defp selected_config(provider, id) do
    with {:ok, id} <- cast_id(id),
         %ChannelConfig{provider: ^provider, kind: "retrieval", archived_at: nil} = config <-
           ChannelConfig.get(id) do
      {:ok, config}
    else
      _ -> {:error, :connector_mismatch}
    end
  end

  defp snapshot_selected(_provider, nil), do: {:ok, nil}
  defp snapshot_selected(provider, selected_id), do: selected_config(provider, selected_id)

  defp normalize_selection(:new, _configs), do: :new
  defp normalize_selection(nil, []), do: :new
  defp normalize_selection(nil, [config]), do: config.id
  defp normalize_selection(nil, _configs), do: nil
  defp normalize_selection(id, _configs), do: id

  defp form_config(@smtp_provider, channel) do
    settings = channel.settings || %{}

    %EmailConfig{
      enabled: channel.enabled,
      relay: map_get(settings, "relay"),
      port: parse_int(map_get(settings, "port"), 587),
      transport_mode: map_get(settings, "transport_mode") || "starttls",
      tls: map_get(settings, "tls") || "enabled",
      tls_verify: map_get(settings, "tls_verify") || "verify_peer",
      ca_cert_path: blank_to_nil(map_get(settings, "ca_cert_path")),
      username: map_get(settings, "username"),
      password: decrypt(map_get(settings, "password")),
      from_email: map_get(settings, "from_email") || "noreply@zaq.local",
      from_name: map_get(settings, "from_name") || "ZAQ"
    }
  end

  defp form_config(@imap_provider, channel) do
    settings = ChannelConfig.imap_settings(channel)

    %ImapConfig{
      enabled: channel.enabled,
      url: channel.url,
      port: parse_int(ImapConfigHelpers.get(settings, "port"), 993),
      ssl: ImapConfigHelpers.get(settings, "ssl") != false,
      username: ImapConfigHelpers.get(settings, "username"),
      password: decrypt(channel.token),
      selected_mailboxes: ImapConfigHelpers.get(settings, "selected_mailboxes") || ["INBOX"],
      mark_as_read: ImapConfigHelpers.get(settings, "mark_as_read") != false,
      load_initial_unread: ImapConfigHelpers.get(settings, "load_initial_unread") == true,
      ssl_depth: parse_int(ImapConfigHelpers.get(settings, "ssl_depth"), 3),
      poll_interval: parse_int(ImapConfigHelpers.get(settings, "poll_interval"), 30_000),
      idle_timeout: parse_int(ImapConfigHelpers.get(settings, "idle_timeout"), 1_500_000)
    }
  end

  defp smtp_config_id(params, channel, enabled?) do
    existing = get_in(channel.settings || %{}, ["imap", "smtp_config_id"])

    case Map.get(params, "smtp_config_id", existing) do
      value when value in [nil, ""] and not enabled? -> {:ok, nil}
      value when value in [nil, ""] -> require_unambiguous_smtp()
      value -> validate_smtp_id(value)
    end
  end

  defp require_unambiguous_smtp do
    case ChannelConfig.resolve_by_provider(@smtp_provider) do
      {:ok, _} -> {:ok, nil}
      _ -> {:error, :missing_smtp_binding}
    end
  end

  defp validate_smtp_id(value) do
    with {:ok, id} <- cast_id(value),
         {:ok, _} <- ChannelConfig.resolve_by_provider(@smtp_provider, id) do
      {:ok, id}
    else
      _ -> {:error, :invalid_smtp_connector}
    end
  end

  defp sync_runtime(saved, opts) do
    router = Keyword.get(opts, :node_router, NodeRouter)
    runtime_opts = Keyword.take(opts, [:runtime_module])

    event =
      Event.new(%{config: runtime_config(saved)}, :channels,
        opts: runtime_opts ++ [action: :sync_provider_runtime, confidential: true]
      )

    case router.dispatch(event) do
      %Event{response: :ok} -> :synced
      %Event{response: {:ok, _}} -> :synced
      %Event{response: {:error, reason}} -> {:pending, reason}
      %Event{response: other} -> {:pending, {:unexpected_response, other}}
      _ -> {:pending, :channels_unavailable}
    end
  rescue
    _ -> {:pending, :runtime_sync_failed}
  catch
    :exit, _ -> {:pending, :channels_unavailable}
  end

  defp runtime_config(saved) do
    config =
      saved
      |> ChannelConfig.to_runtime_config()
      |> Map.take([:id, :provider, :kind, :name, :url, :token, :enabled, :settings])

    if saved.provider == @smtp_provider do
      update_in(config, [:settings, "password"], &decrypt/1)
    else
      config
    end
  end

  defp decrypt(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  defp encrypt_password(value) when value in [nil, ""], do: {:ok, value}

  defp encrypt_password(value) when is_binary(value) do
    if EncryptedString.encrypted?(value), do: {:ok, value}, else: EncryptedString.encrypt(value)
  end

  defp cast_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp cast_id(_), do: :error
  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(value, default), do: ParseUtils.parse_int(value, default)
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp map_get(map, key), do: SmtpHelpers.map_get(map, key)
end
