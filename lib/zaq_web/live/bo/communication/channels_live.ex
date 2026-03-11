# lib/zaq_web/live/bo/communication/channels_live.ex

defmodule ZaqWeb.Live.BO.Communication.ChannelsLive do
  use ZaqWeb, :live_view

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Retrieval.Mattermost
  alias Zaq.Channels.Retrieval.Mattermost.API, as: MattermostAPI
  alias Zaq.Channels.RetrievalChannel, as: RetChannel
  alias Zaq.Repo
  alias ZaqWeb.Components.ServiceUnavailable

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

  # Required roles for this page — just :channels for now.
  # When ingestion channels are separated: [:channels, :ingestion]
  # When retrieval channels are separated: [:channels, :agent]
  @required_roles [:channels]

  @impl true
  def mount(%{"provider" => provider}, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)
    kind = socket.assigns.live_action

    label =
      Map.get(
        @provider_labels,
        provider,
        provider |> String.replace("_", " ") |> String.capitalize()
      )

    back_path =
      case kind do
        :retrieval -> "/bo/channels/retrieval"
        :ingestion -> "/bo/channels/ingestion"
        _ -> "/bo/channels"
      end

    back_label =
      case kind do
        :retrieval -> "Retrieval Channels"
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
     |> assign(:service_available, available)
     |> assign(:required_roles, @required_roles)
     |> assign(:configs, configs)
     # config modal
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
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
     |> assign(:modal_errors, [])}
  end

  def handle_event("open_modal", %{"action" => "edit", "id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)
    changeset = ChannelConfig.changeset(config, %{})

    {:noreply,
     socket
     |> assign(:modal, :edit)
     |> assign(:changeset, changeset)
     |> assign(:modal_errors, [])}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
     |> assign(:modal_errors, [])}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    changeset =
      socket.assigns.changeset.data
      |> ChannelConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    result =
      case socket.assigns.modal do
        :new -> %ChannelConfig{} |> ChannelConfig.changeset(params) |> Repo.insert()
        :edit -> socket.assigns.changeset.data |> ChannelConfig.changeset(params) |> Repo.update()
      end

    case result do
      {:ok, _config} ->
        configs = list_configs(socket.assigns.provider)
        first_config = List.first(configs)

        {:noreply,
         socket
         |> assign(:modal, nil)
         |> assign(:changeset, nil)
         |> assign(:modal_errors, [])
         |> assign(:configs, configs)
         |> assign(:retrieval_channels, load_retrieval_channels(first_config))
         |> put_flash(:info, "Channel config saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
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
         |> assign(:retrieval_channels, load_retrieval_channels(first_config))
         |> put_flash(:info, "Channel config deleted.")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    config = Repo.get!(ChannelConfig, id)

    config
    |> Ecto.Changeset.change(enabled: !config.enabled)
    |> Repo.update!()

    {:noreply,
     socket
     |> assign(:configs, list_configs(socket.assigns.provider))
     |> put_flash(:info, "#{config.name} #{if config.enabled, do: "disabled", else: "enabled"}.")}
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
      case channel_config_module().test_connection(config, String.trim(channel_id)) do
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
    socket = assign(socket, :posts_status, :loading)

    config = ChannelConfig.get_by_provider("mattermost")

    {status, posts} =
      case config do
        nil ->
          {:error, []}

        %ChannelConfig{} = cfg ->
          headers = [{"authorization", "Bearer #{cfg.token}"}]

          case http_client().get(
                 "#{cfg.url}/api/v4/channels/#{String.trim(channel_id)}/posts",
                 headers
               ) do
            {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
              decoded = Jason.decode!(body)

              posts =
                decoded["order"] |> Enum.map(&decoded["posts"][&1]) |> Enum.reject(&is_nil/1)

              {:ok, posts}

            {:ok, %HTTPoison.Response{status_code: status}} ->
              {:error, "HTTP #{status}"}

            {:error, %HTTPoison.Error{reason: reason}} ->
              {:error, inspect(reason)}
          end
      end

    {:noreply,
     socket
     |> assign(:posts_status, status)
     |> assign(:posts, posts)
     |> assign(:posts_channel_id, channel_id)}
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

    status =
      case mattermost_api().clear_channel(channel_id) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

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

  def handle_event("select_team", %{"team-id" => team_id, "team-name" => team_name}, socket) do
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
    notify_ws_reload()

    {:noreply,
     socket
     |> assign(:retrieval_channels, load_retrieval_channels(config))
     |> put_flash(:info, "#{rc.channel_name} #{if rc.active, do: "paused", else: "activated"}.")}
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
    notify_ws_reload()

    {:noreply,
     socket
     |> assign(:confirm_remove_channel, nil)
     |> assign(:retrieval_channels, load_retrieval_channels(config))
     |> put_flash(:info, "#{rc.channel_name} removed.")}
  end

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

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
        notify_ws_reload()

        available =
          Enum.reject(socket.assigns.available_channels, fn ch -> ch.id == ch_id end)

        socket
        |> assign(:retrieval_channels, load_retrieval_channels(cfg))
        |> assign(:available_channels, available)
        |> put_flash(:info, "#{ch_name} added as retrieval channel.")

      {:error, changeset} ->
        errors = format_errors(changeset) |> Enum.join(", ")
        put_flash(socket, :error, "Failed to add channel: #{errors}")
    end
  end

  defp notify_ws_reload do
    if Process.whereis(Mattermost) do
      Mattermost.reload_channels()
    end
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, &"#{Phoenix.Naming.humanize(field)} #{&1}")
    end)
  end

  defp channel_config_module do
    Application.get_env(:zaq, :channels_live_channel_config_module, ChannelConfig)
  end

  defp mattermost_api do
    Application.get_env(:zaq, :channels_live_mattermost_api_module, MattermostAPI)
  end

  defp http_client do
    Application.get_env(:zaq, :channels_live_http_client, HTTPoison)
  end
end
