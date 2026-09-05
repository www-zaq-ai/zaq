defmodule ZaqWeb.Live.BO.Communication.NotificationImapLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  import Zaq.Helpers, only: [blank?: 1]

  require Logger

  alias Zaq.Channels.{AgentRouting, ChannelConfig}
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.NodeRouter
  alias Zaq.System.ImapConfig
  alias Zaq.Types.EncryptedString
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions

  @imap_provider "email:imap"

  @impl true
  def mount(_params, _session, socket) do
    config = current_imap_config()
    channel = ChannelConfig.get_any_by_provider(@imap_provider)
    changeset = ImapConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/channels/retrieval/email/imap")
     |> assign(:page_title, "IMAP Configuration")
     |> assign(:form, to_form(changeset))
     |> assign(:imap_enabled, config.enabled)
     |> assign(:agent_options, AgentRoutingOptions.agent_options())
     |> assign(:provider_default_agent_value, provider_default_agent_value(channel))
     |> assign(:mailbox_agent_assignments, mailbox_agent_assignments(channel))
     |> assign(:mailbox_assignment_targets, selected_mailboxes(config.selected_mailboxes))
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
       :mailbox_assignment_targets,
       selected_mailboxes(Ecto.Changeset.get_field(changeset, :selected_mailboxes, []))
     )
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

    case persist_imap_config(changeset, params) do
      {:ok, _updated_config} ->
        fresh = current_imap_config()
        channel = ChannelConfig.get_any_by_provider(@imap_provider)
        fresh_changeset = ImapConfig.changeset(fresh, %{})
        sync_result = sync_runtime(@imap_provider)

        {:noreply,
         socket
         |> assign_persisted_imap_state(fresh, channel, fresh_changeset)
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

    case persist_imap_config(changeset, %{}) do
      {:ok, _updated_config} ->
        fresh = current_imap_config()
        channel = ChannelConfig.get_any_by_provider(@imap_provider)
        fresh_changeset = ImapConfig.changeset(fresh, %{})
        sync_result = sync_runtime(@imap_provider)

        {:noreply,
         socket
         |> assign_persisted_imap_state(fresh, channel, fresh_changeset)
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
         |> assign(:mailbox_assignment_targets, selected_mailboxes(selected))
         |> assign(:mailbox_status, :ok)}

      {:error, reason} ->
        message = format_load_error(reason)

        Logger.error(
          "[NotificationImapLive] mailbox load failed provider=#{@imap_provider} url=#{inspect(ImapConfigHelpers.get(config, :url))} ssl=#{inspect(ImapConfigHelpers.get(config, :ssl))} port=#{inspect(ImapConfigHelpers.get(config, :port))} username=#{inspect(ImapConfigHelpers.get(config, :username))} reason=#{inspect(reason)}"
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
      port: parse_int(ImapConfigHelpers.get(settings, "port"), 993),
      ssl: ImapConfigHelpers.get(settings, "ssl") != false,
      username: ImapConfigHelpers.get(settings, "username"),
      password: decrypt_token(channel),
      selected_mailboxes: selected_mailboxes_string(settings),
      mark_as_read: ImapConfigHelpers.get(settings, "mark_as_read") != false,
      load_initial_unread: ImapConfigHelpers.get(settings, "load_initial_unread") == true,
      ssl_depth: parse_int(ImapConfigHelpers.get(settings, "ssl_depth"), 3),
      poll_interval: parse_int(ImapConfigHelpers.get(settings, "poll_interval"), 30_000),
      idle_timeout: parse_int(ImapConfigHelpers.get(settings, "idle_timeout"), 1_500_000)
    }
  end

  defp persist_imap_config(%Ecto.Changeset{valid?: true} = changeset, raw_params) do
    config = Ecto.Changeset.apply_changes(changeset)
    channel = ChannelConfig.get_any_by_provider(@imap_provider)
    existing_settings = if(channel, do: channel.settings || %{}, else: %{})

    attrs = %{
      name: "Email IMAP",
      kind: "retrieval",
      url: blank_to_nil(config.url),
      token: blank_to_nil(config.password),
      enabled: config.enabled,
      settings:
        existing_settings
        |> Map.put("imap", %{
          "port" => config.port,
          "ssl" => config.ssl,
          "ssl_depth" => config.ssl_depth,
          "username" => blank_to_nil(config.username),
          "selected_mailboxes" => ImapConfig.normalize_mailboxes(config.selected_mailboxes),
          "mark_as_read" => config.mark_as_read,
          "load_initial_unread" => config.load_initial_unread,
          "poll_interval" => config.poll_interval,
          "idle_timeout" => config.idle_timeout
        })
    }

    with {:ok, channel} <- ChannelConfig.upsert_by_provider(@imap_provider, attrs),
         {:ok, _} <- maybe_persist_provider_default_rule(channel, raw_params),
         {:ok, _} <- maybe_persist_mailbox_agent_rules(channel, raw_params) do
      {:ok, channel}
    end
  end

  defp persist_imap_config(%Ecto.Changeset{valid?: false} = changeset, _raw_params),
    do: {:error, changeset}

  defp provider_default_agent_value(nil), do: ""

  defp provider_default_agent_value(channel),
    do:
      channel
      |> ChannelConfig.get_provider_agent_choice()
      |> AgentRouting.select_value()

  defp mailbox_agent_assignments(nil), do: %{}

  defp mailbox_agent_assignments(channel) do
    channel.settings
    |> get_in(["imap", "selected_mailboxes"])
    |> selected_mailboxes()
    |> Map.new(fn mailbox ->
      value =
        case IncomingMessageRouting.get_rule(%{channel_config_id: channel.id, topic_id: mailbox}) do
          %{routing_mode: :none} -> AgentRouting.none_value()
          %{routing_mode: :agent, configured_agent_id: configured_agent_id} -> configured_agent_id
          _ -> nil
        end

      {mailbox, value}
    end)
    |> Enum.reject(fn {_mailbox, value} -> is_nil(value) end)
    |> Map.new()
  end

  def mailbox_agent_value(assignments, mailbox) when is_map(assignments) do
    assignments
    |> Map.get(mailbox)
    |> AgentRouting.select_value()
  end

  def mailbox_agent_value(_assignments, _mailbox), do: ""

  defp parse_mailbox_agents(mailbox_agent_ids) when is_map(mailbox_agent_ids) do
    mailbox_agent_ids
    |> Enum.reduce(%{}, fn {mailbox, raw_id}, acc ->
      mailbox_key = String.trim(to_string(mailbox || ""))

      case {mailbox_key, sanitize_agent_choice(raw_id)} do
        {"", _} -> acc
        {_, nil} -> acc
        {key, choice} -> Map.put(acc, key, choice)
      end
    end)
  end

  defp parse_mailbox_agents(_), do: %{}

  defp sanitize_mailbox_agents(mailbox_agents) when is_map(mailbox_agents) do
    mailbox_agents
    |> Enum.reduce(%{}, fn {mailbox, id}, acc ->
      case sanitize_agent_choice(id) do
        nil -> acc
        valid_choice -> Map.put(acc, mailbox, valid_choice)
      end
    end)
  end

  defp sanitize_mailbox_agents(_), do: %{}

  defp sanitize_agent_choice(raw_id) do
    case AgentRouting.validate_choice(raw_id) do
      {:ok, :none} -> AgentRouting.none_value()
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp maybe_persist_provider_default_rule(channel, %{"provider_default_agent_id" => raw_id}) do
    case sanitize_agent_choice(raw_id) do
      nil ->
        upsert_incoming_routing_rule(routing_rule(%{channel_config_id: channel.id}, nil))

      choice ->
        upsert_incoming_routing_rule(routing_rule(%{channel_config_id: channel.id}, choice))
    end
  end

  defp maybe_persist_provider_default_rule(_channel, _raw_params), do: {:ok, nil}

  defp maybe_persist_mailbox_agent_rules(channel, %{"mailbox_agent_ids" => mailbox_agent_ids}) do
    mailbox_agents =
      mailbox_agent_ids
      |> parse_mailbox_agents()
      |> sanitize_mailbox_agents()

    selected = channel.settings |> get_in(["imap", "selected_mailboxes"]) |> selected_mailboxes()

    rules =
      Enum.map(selected, fn mailbox ->
        scope = %{channel_config_id: channel.id, topic_id: mailbox}
        routing_rule(scope, Map.get(mailbox_agents, mailbox))
      end)

    upsert_incoming_routing_rules(rules)
  end

  defp maybe_persist_mailbox_agent_rules(_channel, _raw_params), do: {:ok, []}

  defp routing_rule(scope, nil), do: Map.put(scope, :routing_mode, :clear)

  defp routing_rule(scope, configured_agent_id) do
    if configured_agent_id in [:none, "none"] or configured_agent_id == AgentRouting.none_value() do
      Map.put(scope, :routing_mode, :none)
    else
      Map.merge(scope, %{routing_mode: :agent, configured_agent_id: configured_agent_id})
    end
  end

  defp upsert_incoming_routing_rule(rule),
    do: upsert_incoming_routing_rules([rule])

  defp upsert_incoming_routing_rules(rules),
    do: dispatch_engine(:upsert_incoming_message_routing_rules, %{rules: rules})

  defp selected_mailboxes(value), do: ImapConfig.normalize_mailboxes(value)

  defp selected_mailboxes_string(settings) do
    settings
    |> ImapConfigHelpers.get("selected_mailboxes")
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
          list_mailboxes(config)
        rescue
          error -> {:error, {:mailbox_load_failed, Exception.message(error)}}
        catch
          :exit, reason -> {:error, {:mailbox_load_failed, reason}}
        end

      send(caller, {:load_mailboxes_result, config, selected, result})
    end)
  end

  defp sync_runtime(provider) do
    channels_mod = channels_module()
    node_router_mod = node_router_module()

    request =
      if channels_mod == Zaq.Channels.Api do
        %{provider: provider}
      else
        %{module: channels_mod, function: :sync_provider_runtime, args: [provider]}
      end

    request
    |> Zaq.Event.new(:channels, opts: [action: :sync_provider_runtime])
    |> node_router_mod.dispatch()
    |> Map.get(:response)
  end

  defp list_mailboxes(config) do
    channels_mod = channels_module()
    node_router_mod = node_router_module()

    request =
      if channels_mod == Zaq.Channels.Api do
        %{provider: @imap_provider, config: config}
      else
        %{module: channels_mod, function: :list_mailboxes, args: [@imap_provider, config]}
      end

    request
    |> Zaq.Event.new(:channels, opts: [action: :list_mailboxes])
    |> node_router_mod.dispatch()
    |> Map.get(:response)
  end

  defp dispatch_engine(action, request) do
    node_router = node_router_module()

    node_router.dispatch(Zaq.Event.new(request, :engine, opts: [action: action]))
    |> Map.get(:response)
  end

  defp assign_persisted_imap_state(socket, fresh, channel, fresh_changeset) do
    socket
    |> assign(:imap_enabled, fresh.enabled)
    |> assign(:provider_default_agent_value, provider_default_agent_value(channel))
    |> assign(:mailbox_agent_assignments, mailbox_agent_assignments(channel))
    |> assign(:mailbox_assignment_targets, selected_mailboxes(fresh.selected_mailboxes))
    |> assign(:form, to_form(fresh_changeset))
    |> assign(
      :available_mailboxes,
      mailbox_options(fresh.selected_mailboxes, socket.assigns.available_mailboxes)
    )
  end

  defp maybe_put_runtime_sync_flash(socket, :ok), do: socket
  defp maybe_put_runtime_sync_flash(socket, nil), do: socket

  defp maybe_put_runtime_sync_flash(socket, {:error, reason}) do
    put_flash(socket, :error, "IMAP runtime sync failed: #{inspect(reason)}")
  end

  defp mailbox_options(selected, available) do
    ImapConfigHelpers.normalize_mailbox_names(List.wrap(selected) ++ List.wrap(available))
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

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp channels_module,
    do: Application.get_env(:zaq, :notification_imap_router_module, Zaq.Channels.Api)

  defp node_router_module,
    do: Application.get_env(:zaq, :notification_imap_node_router_module, NodeRouter)
end
