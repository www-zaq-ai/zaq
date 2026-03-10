defmodule ZaqWeb.Live.BO.Communication.ChannelsLive do
  use ZaqWeb, :live_view

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Retrieval.Mattermost.API, as: MattermostAPI
  alias Zaq.Repo
  alias ZaqWeb.Components.ServiceUnavailable

  import Ecto.Query

  @provider_labels %{
    "slack" => "Slack",
    "teams" => "Microsoft Teams",
    "mattermost" => "Mattermost",
    "ai_agents" => "AI Agents",
    "discord" => "Discord",
    "telegram" => "Telegram",
    "webhook" => "Webhook"
  }

  # Required roles for this page — just :channels for now.
  # When ingestion channels are separated: [:channels, :ingestion]
  # When retrieval channels are separated: [:channels, :agent]
  @required_roles [:channels]

  @impl true
  def mount(%{"provider" => provider}, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)

    label =
      Map.get(
        @provider_labels,
        provider,
        provider |> String.replace("_", " ") |> String.capitalize()
      )

    {:ok,
     socket
     |> assign(:page_title, label)
     |> assign(:current_path, "/bo/channels")
     |> assign(:provider, provider)
     |> assign(:provider_label, label)
     |> assign(:service_available, available)
     |> assign(:required_roles, @required_roles)
     |> assign(:configs, if(available, do: list_configs(provider), else: []))
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
     |> assign(:clear_status, :idle)}
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
        {:noreply,
         socket
         |> assign(:modal, nil)
         |> assign(:changeset, nil)
         |> assign(:modal_errors, [])
         |> assign(:configs, list_configs(socket.assigns.provider))
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

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> assign(:configs, list_configs(socket.assigns.provider))
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
      case ChannelConfig.test_connection(config, String.trim(channel_id)) do
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
      case MattermostAPI.send_message(String.trim(channel_id), String.trim(message)) do
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

          case HTTPoison.get(
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
      case MattermostAPI.clear_channel(channel_id) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:noreply,
     socket
     |> assign(:clear_status, status)
     |> assign(:confirm_clear, false)}
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
end
