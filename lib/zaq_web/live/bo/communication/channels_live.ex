defmodule ZaqWeb.Live.BO.Communication.ChannelsLive do
  use ZaqWeb, :live_view

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Channels")
     |> assign(:current_path, "/bo/channels")
     |> assign(:configs, list_configs())
     |> assign(:modal, nil)
     |> assign(:changeset, nil)
     |> assign(:modal_errors, [])
     |> assign(:confirm_delete, nil)
     |> assign(:test_config, nil)
     |> assign(:test_status, :idle)
     |> assign(:test_channel_id, "")}
  end

  # --- Events ---

  @impl true
  def handle_event("open_modal", %{"action" => "new"}, socket) do
    changeset = ChannelConfig.changeset(%ChannelConfig{}, %{})

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
         |> assign(:configs, list_configs())
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
         |> assign(:configs, list_configs())
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
     |> assign(:configs, list_configs())
     |> put_flash(:info, "#{config.name} #{if config.enabled, do: "disabled", else: "enabled"}.")}
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

  # --- Private ---

  defp list_configs do
    ChannelConfig
    |> order_by(asc: :provider)
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
