# lib/zaq_web/live/bo/communication/channels_live.ex

defmodule ZaqWeb.Live.BO.Communication.ChannelsLive do
  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.Agent
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel, as: RetChannel
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.RuntimeDeps
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils
  alias ZaqWeb.ChangesetErrors

  import Ecto.Query

  @provider_labels %{
    # Retrieval
    "slack" => "Slack",
    "teams" => "Microsoft Teams",
    "mattermost" => "Mattermost",
    "discord" => "Discord",
    "telegram" => "Telegram",
    "webhook" => "Webhook",
    # Ingestion
    "zaq_local" => "ZAQ Local",
    "google_drive" => "Google Drive",
    "sharepoint" => "SharePoint"
  }

  @impl true
  def mount(%{"provider" => provider}, _session, socket) do
    available = socket.assigns.service_available
    kind = socket.assigns.live_action

    label =
      Map.get(
        @provider_labels,
        provider,
        provider |> String.replace("_", " ") |> String.capitalize()
      )

    back_path =
      case kind do
        :retrieval -> ~p"/bo/channels/retrieval"
        :ingestion -> ~p"/bo/channels/ingestion"
        _ -> ~p"/bo/channels"
      end

    back_label =
      case kind do
        :retrieval -> "Communication Channels"
        :ingestion -> "Ingestion Channels"
        _ -> "All Channels"
      end

    configs = if(available, do: list_configs(provider), else: [])
    first_config = List.first(configs)

    {:ok,
     socket
     |> assign(:page_title, label)
     |> assign(:current_path, back_path)
     |> assign(:back_path, back_path)
     |> assign(:back_label, back_label)
     |> assign(:kind, kind)
     |> assign(:provider, provider)
     |> assign(:provider_label, label)
     |> assign(:configs, configs)
     |> assign(:agent_options, agent_options())
     |> assign(:provider_default_agent_id, provider_default_agent_id(first_config))
     # config modal
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
     |> assign(:form, nil)
     |> assign(:modal_errors, [])
     |> assign(:confirm_delete, nil)
     # test connection
     |> assign(:test_config, nil)
     |> assign(:test_status, :idle)
     |> assign(:test_channel_id, "")
     # send message panel
     |> assign(:send_channel_id, "")
     |> assign(:send_message, "")
     |> assign(:send_status, :idle)
     # posts viewer
     |> assign(:posts_channel_id, "")
     |> assign(:posts, [])
     |> assign(:posts_status, :idle)
     |> assign(:posts_next_id, nil)
     |> assign(:posts_prev_id, nil)
     # clear channel
     |> assign(:clear_channel_id, "")
     |> assign(:confirm_clear, false)
     |> assign(:clear_status, :idle)
     # --- retrieval channel picker ---
     |> assign(:retrieval_channels, load_retrieval_channels(first_config))
     |> assign(:teams, [])
     |> assign(:teams_status, :idle)
     |> assign(:available_channels, [])
     |> assign(:channels_status, :idle)
     |> assign(:selected_team_id, nil)
     |> assign(:selected_team_name, nil)
     |> assign(:confirm_remove_channel, nil)}
  end

  # -------------------------------------------------------------------------
  # Guard — ignore all events when service is unavailable
  # -------------------------------------------------------------------------

  @impl true
  def handle_event(_event, _params, %{assigns: %{service_available: false}} = socket) do
    {:noreply, socket}
  end

  # -------------------------------------------------------------------------
  # Config CRUD events
  # -------------------------------------------------------------------------

  def handle_event("open_modal", %{"action" => "new"}, socket) do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{"provider" => socket.assigns.provider})

    {:noreply,
     socket
     |> assign(:modal, :new)
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset, as: :form))
     |> assign(:modal_errors, [])}
  end

  def handle_event("open_modal", %{"action" => "edit", "id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)
    changeset = config |> ChannelConfig.changeset(%{}) |> with_visible_token()

    {:noreply,
     socket
     |> assign(:modal, :edit)
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
     |> assign(:modal_errors, [])}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    raw_token = Map.get(params, "token")

    params =
      case socket.assigns.modal do
        :edit -> if params["token"] == "", do: Map.delete(params, "token"), else: params
        _ -> params
      end

    changeset =
      socket.assigns.changeset.data
      |> ChannelConfig.changeset(params)
      |> with_visible_token(raw_token)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset, as: :form))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    previous_config =
      if socket.assigns.modal == :edit, do: socket.assigns.changeset.data, else: nil

    raw_token = Map.get(params, "token")

    params =
      case socket.assigns.modal do
        :edit -> if params["token"] == "", do: Map.delete(params, "token"), else: params
        _ -> params
      end

    result =
      case socket.assigns.modal do
        :new -> %ChannelConfig{} |> ChannelConfig.changeset(params) |> Repo.insert()
        :edit -> socket.assigns.changeset.data |> ChannelConfig.changeset(params) |> Repo.update()
      end

    case result do
      {:ok, config} ->
        sync_result =
          NodeRouter.call(:channels, Zaq.Channels.Router, :sync_config_runtime, [
            previous_config,
            config
          ])

        configs = list_configs(socket.assigns.provider)
        first_config = List.first(configs)

        {:noreply,
         socket
         |> assign(:modal, nil)
         |> assign(:changeset, nil)
         |> assign(:form, nil)
         |> assign(:modal_errors, [])
         |> assign(:configs, configs)
         |> assign(:provider_default_agent_id, provider_default_agent_id(first_config))
         |> assign(:retrieval_channels, load_retrieval_channels(first_config))
         |> maybe_put_runtime_sync_flash(sync_result, "Channel config saved.")}

      {:error, changeset} ->
        changeset = with_visible_token(changeset, raw_token)

        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> assign(:form, to_form(changeset, as: :form))
         |> assign(:modal_errors, format_errors(changeset))}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete, id)}
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
        configs = list_configs(socket.assigns.provider)
        first_config = List.first(configs)

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> assign(:configs, configs)
         |> assign(:provider_default_agent_id, provider_default_agent_id(first_config))
         |> assign(:retrieval_channels, load_retrieval_channels(first_config))
         |> put_flash(:info, "Channel config deleted.")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    previous_config = Repo.get!(ChannelConfig, id)

    config =
      previous_config
      |> Ecto.Changeset.change(enabled: !previous_config.enabled)
      |> Repo.update!()

    sync_result =
      NodeRouter.call(:channels, Zaq.Channels.Router, :sync_config_runtime, [
        previous_config,
        config
      ])

    configs = list_configs(socket.assigns.provider)
    first_config = List.first(configs)

    {:noreply,
     socket
     |> assign(:configs, configs)
     |> assign(:provider_default_agent_id, provider_default_agent_id(first_config))
     |> maybe_put_runtime_sync_flash(
       sync_result,
       "#{config.name} #{if previous_config.enabled, do: "disabled", else: "enabled"}."
     )}
  end

  def handle_event(
        "set_provider_default_agent",
        %{"config_id" => config_id, "configured_agent_id" => raw_id},
        socket
      ) do
    with {:ok, id} <- ParseUtils.parse_int_strict(config_id),
         %ChannelConfig{} = config <- Repo.get(ChannelConfig, id),
         {:ok, updated} <-
           ChannelConfig.set_provider_default_agent_id(
             config,
             ParseUtils.parse_optional_int(raw_id)
           ) do
      sync_result =
        NodeRouter.call(:channels, Zaq.Channels.Router, :sync_config_runtime, [
          config,
          updated
        ])

      configs = list_configs(socket.assigns.provider)
      first_config = List.first(configs)

      {:noreply,
       socket
       |> assign(:configs, configs)
       |> assign(:provider_default_agent_id, provider_default_agent_id(first_config))
       |> maybe_put_runtime_sync_flash(sync_result, "Provider default agent updated.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update provider default agent.")}
    end
  end

  def handle_event(
        "set_retrieval_channel_agent",
        %{"retrieval_channel_id" => id, "configured_agent_id" => raw_id},
        socket
      ) do
    with {:ok, rc_id} <- ParseUtils.parse_int_strict(id),
         %RetChannel{} = retrieval_channel <- Repo.get(RetChannel, rc_id),
         {:ok, _updated} <-
           retrieval_channel
           |> RetChannel.changeset(%{configured_agent_id: ParseUtils.parse_optional_int(raw_id)})
           |> Repo.update() do
      config = first_enabled_config(socket)

      {:noreply,
       socket
       |> assign(:retrieval_channels, load_retrieval_channels(config))
       |> put_flash(:info, "Channel agent assignment updated.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update channel agent assignment.")}
    end
  end

  # -------------------------------------------------------------------------
  # Test connection
  # -------------------------------------------------------------------------

  def handle_event("open_test", %{"id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)

    {:noreply,
     socket
     |> assign(:test_config, config)
     |> assign(:test_status, :idle)
     |> assign(:test_channel_id, "")}
  end

  def handle_event("close_test", _params, socket) do
    {:noreply,
     socket
     |> assign(:test_config, nil)
     |> assign(:test_status, :idle)
     |> assign(:test_channel_id, "")}
  end

  def handle_event("run_test", %{"channel_id" => channel_id}, socket) do
    config = socket.assigns.test_config
    socket = assign(socket, :test_status, :testing)

    status =
      case NodeRouter.call(:channels, Zaq.Channels.Router, :test_connection, [
             config,
             String.trim(channel_id)
           ]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :test_status, status)}
  end

  # -------------------------------------------------------------------------
  # Mattermost: Send Message
  # -------------------------------------------------------------------------

  def handle_event("send_message", %{"channel_id" => channel_id, "message" => message}, socket) do
    socket = assign(socket, :send_status, :sending)

    status =
      case mattermost_api().send_message(String.trim(channel_id), String.trim(message)) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:noreply,
     socket
     |> assign(:send_status, status)
     |> assign(:send_channel_id, channel_id)
     |> assign(:send_message, if(status == :ok, do: "", else: message))}
  end

  def handle_event("reset_send", _params, socket) do
    {:noreply,
     socket
     |> assign(:send_status, :idle)
     |> assign(:send_message, "")}
  end

  # -------------------------------------------------------------------------
  # Mattermost: Browse Posts
  # -------------------------------------------------------------------------

  def handle_event("load_posts", %{"channel_id" => channel_id}, socket) do
    fetch_posts(socket, String.trim(channel_id), [])
  end

  def handle_event("load_older_posts", _params, socket) do
    fetch_posts(socket, socket.assigns.posts_channel_id, before: socket.assigns.posts_prev_id)
  end

  def handle_event("load_newer_posts", _params, socket) do
    fetch_posts(socket, socket.assigns.posts_channel_id, after: socket.assigns.posts_next_id)
  end

  # -------------------------------------------------------------------------
  # Mattermost: Clear Channel
  # -------------------------------------------------------------------------

  def handle_event("prompt_clear", %{"channel_id" => channel_id}, socket) do
    {:noreply,
     socket
     |> assign(:clear_channel_id, channel_id)
     |> assign(:confirm_clear, true)}
  end

  def handle_event("cancel_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_clear, false)
     |> assign(:clear_status, :idle)}
  end

  def handle_event("run_clear", _params, socket) do
    channel_id = socket.assigns.clear_channel_id
    socket = assign(socket, :clear_status, :clearing)

    status = mattermost_api().clear_channel(channel_id)

    {:noreply,
     socket
     |> assign(:clear_status, status)
     |> assign(:confirm_clear, false)}
  end

  # -------------------------------------------------------------------------
  # Retrieval Channel Picker
  # -------------------------------------------------------------------------

  def handle_event("fetch_teams", _params, socket) do
    config = first_enabled_config(socket)

    case config do
      nil ->
        {:noreply, put_flash(socket, :error, "No enabled Mattermost config found.")}

      %ChannelConfig{} = cfg ->
        socket = assign(socket, :teams_status, :loading)

        case mattermost_api().list_teams(cfg) do
          {:ok, teams} ->
            {:noreply,
             socket
             |> assign(:teams, teams)
             |> assign(:teams_status, :ok)
             |> assign(:available_channels, [])
             |> assign(:channels_status, :idle)
             |> assign(:selected_team_id, nil)
             |> assign(:selected_team_name, nil)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:teams, [])
             |> assign(:teams_status, {:error, reason})}
        end
    end
  end

  def handle_event("select_team", %{"team_id" => team_id, "team_name" => team_name}, socket) do
    config = first_enabled_config(socket)

    case config do
      nil ->
        {:noreply, put_flash(socket, :error, "No enabled Mattermost config found.")}

      %ChannelConfig{} = cfg ->
        socket =
          socket
          |> assign(:selected_team_id, team_id)
          |> assign(:selected_team_name, team_name)
          |> assign(:channels_status, :loading)

        {:noreply, fetch_and_assign_channels(socket, cfg, team_id)}
    end
  end

  def handle_event("add_channel", %{"channel-id" => ch_id, "channel-name" => ch_name}, socket) do
    config = first_enabled_config(socket)

    case config do
      nil ->
        {:noreply, put_flash(socket, :error, "No enabled Mattermost config found.")}

      %ChannelConfig{} = cfg ->
        attrs = %{
          channel_config_id: cfg.id,
          channel_id: ch_id,
          channel_name: ch_name,
          team_id: socket.assigns.selected_team_id,
          team_name: socket.assigns.selected_team_name,
          active: true
        }

        {:noreply, insert_retrieval_channel(socket, cfg, attrs, ch_id, ch_name)}
    end
  end

  def handle_event("toggle_channel_active", %{"id" => id}, socket) do
    rc = Repo.get!(RetChannel, id)

    rc
    |> Ecto.Changeset.change(active: !rc.active)
    |> Repo.update!()

    config = first_enabled_config(socket)
    sync_result = sync_provider_runtime(config)

    {:noreply,
     socket
     |> assign(:retrieval_channels, load_retrieval_channels(config))
     |> maybe_put_runtime_sync_flash(
       sync_result,
       "#{rc.channel_name} #{if rc.active, do: "paused", else: "activated"}."
     )}
  end

  def handle_event("confirm_remove_channel", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_remove_channel, id)}
  end

  def handle_event("cancel_remove_channel", _params, socket) do
    {:noreply, assign(socket, :confirm_remove_channel, nil)}
  end

  def handle_event("remove_channel", _params, socket) do
    id = socket.assigns.confirm_remove_channel
    rc = Repo.get!(RetChannel, id)
    Repo.delete!(rc)

    config = first_enabled_config(socket)
    sync_result = sync_provider_runtime(config)

    {:noreply,
     socket
     |> assign(:confirm_remove_channel, nil)
     |> assign(:retrieval_channels, load_retrieval_channels(config))
     |> maybe_put_runtime_sync_flash(sync_result, "#{rc.channel_name} removed.")}
  end

  # -------------------------------------------------------------------------
  # Fetch bot user ID
  # -------------------------------------------------------------------------

  def handle_event("fetch_bot_user_id", _params, socket) do
    changeset = socket.assigns.changeset
    url = Ecto.Changeset.get_field(changeset, :url)
    token = Ecto.Changeset.get_field(changeset, :token) |> EncryptedString.decrypt!()

    cond do
      is_nil(url) or url == "" ->
        {:noreply, put_flash(socket, :error, "URL is required to fetch the bot user ID.")}

      is_nil(token) or token == "" ->
        {:noreply, put_flash(socket, :error, "Token is required to fetch the bot user ID.")}

      true ->
        case mattermost_api().fetch_bot_user_id(url, token) do
          {:ok, user_id} ->
            settings = Ecto.Changeset.get_field(changeset, :settings) || %{}

            new_settings =
              settings
              |> Map.put_new("jido_chat", %{})
              |> put_in(["jido_chat", "bot_user_id"], user_id)

            new_cs = Ecto.Changeset.put_change(changeset, :settings, new_settings)
            {:noreply, assign(socket, changeset: new_cs, form: to_form(new_cs, as: :form))}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to fetch bot user ID: #{inspect(reason)}")}
        end
    end
  end

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

  defp fetch_posts(socket, channel_id, cursor_opts) do
    socket = assign(socket, :posts_status, :loading)
    {status, posts, next_id, prev_id} = do_fetch_posts(channel_id, cursor_opts)

    {:noreply,
     socket
     |> assign(:posts_status, status)
     |> assign(:posts, posts)
     |> assign(:posts_channel_id, channel_id)
     |> assign(:posts_next_id, next_id)
     |> assign(:posts_prev_id, prev_id)}
  end

  defp do_fetch_posts(channel_id, cursor_opts) do
    case ChannelConfig.get_by_provider("mattermost") do
      nil -> {:error, [], nil, nil}
      %ChannelConfig{} = cfg -> fetch_posts_from_config(cfg, channel_id, cursor_opts)
    end
  end

  defp fetch_posts_from_config(cfg, channel_id, cursor_opts) do
    headers = [{"authorization", "Bearer #{cfg.token}"}]
    params = [{:per_page, 20} | Keyword.take(cursor_opts, [:before, :after])]

    case http_client().get(
           "#{cfg.url}/api/v4/channels/#{channel_id}/posts",
           headers: headers,
           params: params
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {posts, next_id, prev_id} = parse_posts_response(body)
        {:ok, posts, next_id, prev_id}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}", nil, nil}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, inspect(reason), nil, nil}

      {:error, reason} ->
        {:error, inspect(reason), nil, nil}
    end
  end

  defp parse_posts_response(body) do
    decoded = decode_posts_body(body)
    posts_map = decoded["posts"] || %{}

    all_posts =
      (decoded["order"] || [])
      |> Enum.map(&posts_map[&1])
      |> Enum.reject(&is_nil/1)

    replies_by_root = build_replies_by_root(all_posts)
    nested_reply_ids = build_nested_reply_ids(all_posts)

    posts =
      all_posts
      |> Enum.reject(fn p ->
        blank = String.trim(p["message"] || "") == ""
        is_nested_reply = MapSet.member?(nested_reply_ids, p["id"])
        (blank and not Map.has_key?(replies_by_root, p["id"])) or is_nested_reply
      end)
      |> Enum.map(fn p -> {p, Map.get(replies_by_root, p["id"], [])} end)

    {posts, decoded["next_post_id"], decoded["prev_post_id"]}
  end

  defp build_replies_by_root(all_posts) do
    all_posts
    |> Enum.filter(&((&1["root_id"] || "") != ""))
    |> Enum.group_by(& &1["root_id"])
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp build_nested_reply_ids(all_posts) do
    batch_ids = MapSet.new(all_posts, & &1["id"])

    all_posts
    |> Enum.filter(fn p ->
      root = p["root_id"] || ""
      root != "" and MapSet.member?(batch_ids, root)
    end)
    |> MapSet.new(& &1["id"])
  end

  defp list_configs(provider) do
    ChannelConfig
    |> where([c], c.provider == ^provider)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp first_enabled_config(socket) do
    Enum.find(socket.assigns.configs, & &1.enabled)
  end

  defp load_retrieval_channels(nil), do: []

  defp load_retrieval_channels(%ChannelConfig{} = config) do
    RetChannel.list_by_config(config.id)
  end

  defp provider_default_agent_id(nil), do: nil

  defp provider_default_agent_id(%ChannelConfig{} = config),
    do: ChannelConfig.get_provider_default_agent_id(config)

  defp agent_options do
    Agent.list_active_agents()
    |> Enum.map(fn agent -> {agent.name, agent.id} end)
  end

  defp fetch_and_assign_channels(socket, cfg, team_id) do
    case mattermost_api().list_public_channels(cfg, team_id) do
      {:ok, channels} ->
        existing_ids =
          socket.assigns.retrieval_channels
          |> Enum.map(& &1.channel_id)
          |> MapSet.new()

        available = Enum.reject(channels, fn ch -> MapSet.member?(existing_ids, ch.id) end)

        socket
        |> assign(:available_channels, available)
        |> assign(:channels_status, :ok)

      {:error, reason} ->
        socket
        |> assign(:available_channels, [])
        |> assign(:channels_status, {:error, reason})
    end
  end

  defp insert_retrieval_channel(socket, cfg, attrs, ch_id, ch_name) do
    case %RetChannel{} |> RetChannel.changeset(attrs) |> Repo.insert() do
      {:ok, _rc} ->
        sync_result = sync_provider_runtime(cfg)

        available =
          Enum.reject(socket.assigns.available_channels, fn ch -> ch.id == ch_id end)

        socket
        |> assign(:retrieval_channels, load_retrieval_channels(cfg))
        |> assign(:available_channels, available)
        |> maybe_put_runtime_sync_flash(sync_result, "#{ch_name} added as retrieval channel.")

      {:error, changeset} ->
        errors = format_errors(changeset) |> Enum.join(", ")
        put_flash(socket, :error, "Failed to add channel: #{errors}")
    end
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    ChangesetErrors.format(changeset,
      join: false,
      humanize_fields: true,
      field_separator: " "
    )
  end

  defp mattermost_api do
    RuntimeDeps.mattermost_api()
  end

  defp http_client do
    RuntimeDeps.http_client()
  end

  defp decode_posts_body(body) when is_map(body), do: body

  defp decode_posts_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"order" => [], "posts" => %{}}
    end
  end

  defp decode_posts_body(_), do: %{"order" => [], "posts" => %{}}

  defp maybe_put_runtime_sync_flash(socket, :ok, success_message) do
    put_flash(socket, :info, success_message)
  end

  defp maybe_put_runtime_sync_flash(socket, {:error, reason}, success_message) do
    socket
    |> put_flash(:info, success_message)
    |> put_flash(:error, "Runtime sync failed: #{inspect(reason)}")
  end

  defp maybe_put_runtime_sync_flash(socket, other, success_message) do
    socket
    |> put_flash(:info, success_message)
    |> put_flash(:error, "Runtime sync returned unexpected result: #{inspect(other)}")
  end

  defp with_visible_token(changeset, raw_token \\ nil)

  defp with_visible_token(%Ecto.Changeset{} = changeset, raw_token) when is_binary(raw_token) do
    Ecto.Changeset.put_change(changeset, :token, raw_token)
  end

  defp with_visible_token(%Ecto.Changeset{} = changeset, _raw_token) do
    case changeset.data do
      %ChannelConfig{token: token} when is_binary(token) and token != "" ->
        Ecto.Changeset.put_change(changeset, :token, token)

      _ ->
        changeset
    end
  end

  defp sync_provider_runtime(nil), do: :ok

  defp sync_provider_runtime(%ChannelConfig{provider: provider}) do
    NodeRouter.call(:channels, Zaq.Channels.Router, :sync_provider_runtime, [provider])
  end

  def jido_chat_bot_name(%ChannelConfig{} = config) do
    config.settings
    |> Map.get("jido_chat", %{})
    |> Map.get("bot_name")
  end

  def jido_chat_bot_user_id(%ChannelConfig{} = config) do
    config.settings
    |> Map.get("jido_chat", %{})
    |> Map.get("bot_user_id")
  end

  def jido_chat_bot_name_from_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_field(:settings, %{})
    |> Map.get("jido_chat", %{})
    |> Map.get("bot_name", "")
  end

  def jido_chat_bot_user_id_from_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_field(:settings, %{})
    |> Map.get("jido_chat", %{})
    |> Map.get("bot_user_id", "")
  end
end
