defmodule ZaqWeb.Live.BO.System.AddonsLive do
  use ZaqWeb, :live_view

  alias Zaq.Addons.{FeatureStore, PackageLoader}

  @zaq_features [
    %{
      key: "ontology",
      name: "Ontology Management",
      description:
        "Build and manage your organization's knowledge graph with automated entity extraction and relationship mapping.",
      icon: "ontology"
    },
    %{
      key: "knowledge_gap",
      name: "Knowledge Gap Detection",
      description:
        "Automatically identify missing information and suggest content that should be added to your knowledge base.",
      icon: "knowledge_gap"
    },
    %{
      key: "knowledge_update",
      name: "Knowledge Update",
      description:
        "Automatically refresh and update your knowledge base as source documents change, keeping answers accurate over time.",
      icon: "knowledge_update"
    },
    %{
      key: "document_update",
      name: "Document Update",
      description:
        "Track document revisions and propagate changes through the knowledge pipeline automatically on every update.",
      icon: "document_update"
    }
  ]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "addons:updated")
    end

    {:ok,
     socket
     |> assign_addon_state()
     |> assign(current_path: "/bo/addons", upload_error: nil)
     |> allow_upload(:addon_package, accept: ~w(.zaq-license), max_entries: 1)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_addon", _params, socket) do
    result =
      consume_uploaded_entries(socket, :addon_package, fn %{path: tmp_path}, entry ->
        dest_dir = Application.app_dir(:zaq, "priv/licenses")
        File.mkdir_p!(dest_dir)
        dest = Path.join(dest_dir, entry.client_name)
        File.cp!(tmp_path, dest)

        case PackageLoader.load(dest) do
          {:ok, _addon_data} -> {:ok, :loaded}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case result do
      [:loaded] ->
        {:noreply, socket |> assign_addon_state() |> assign(upload_error: nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, upload_error: format_upload_error(reason))}

      [] ->
        {:noreply, assign(socket, upload_error: "No file selected.")}
    end
  end

  def handle_info(:addons_updated, socket) do
    {:noreply, assign_addon_state(socket)}
  end

  defp assign_addon_state(socket) do
    addon_data = FeatureStore.addon_data()
    loaded_modules = FeatureStore.loaded_modules()

    enabled_keys =
      case addon_data do
        nil -> []
        data -> data |> Map.get("features", []) |> Enum.map(& &1["name"])
      end

    feature_lookup = Map.new(@zaq_features, &{&1.key, &1})

    enabled_features =
      enabled_keys
      |> Enum.map(fn key -> Map.get(feature_lookup, key, %{key: key, name: key, icon: nil}) end)

    disabled_features = Enum.reject(@zaq_features, fn f -> f.key in enabled_keys end)

    assign(socket,
      addon_data: addon_data,
      loaded_modules: loaded_modules,
      zaq_features: @zaq_features,
      enabled_features: enabled_features,
      disabled_features: disabled_features
    )
  end

  def upload_entry_error(:too_large), do: "File is too large."
  def upload_entry_error(:not_accepted), do: "Only .zaq-license add-on packages are accepted."
  def upload_entry_error(:too_many_files), do: "Only one file at a time."
  def upload_entry_error(_), do: "Upload failed."

  defp format_upload_error(:license_expired), do: "This add-on package has expired."

  defp format_upload_error(:missing_license_dat),
    do: "Invalid add-on package: missing package data."

  defp format_upload_error(:invalid_payload_json),
    do: "Invalid add-on package: malformed payload."

  defp format_upload_error(:invalid_license_dat_format), do: "Invalid add-on package format."
  defp format_upload_error({:extract_failed, _}), do: "Could not read add-on package."
  defp format_upload_error(reason), do: "Failed to load add-on package: #{inspect(reason)}"

  defp seconds_left(nil), do: nil

  defp seconds_left(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now(), :second)
      _ -> nil
    end
  end

  defp format_time_left(nil), do: nil

  defp format_time_left(seconds) when seconds < 0, do: "Expired"

  defp format_time_left(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days >= 2 -> "#{days} days"
      days == 1 -> "1 day #{hours}h"
      hours >= 1 -> "#{hours}h #{minutes}min"
      true -> "#{minutes}min"
    end
  end

  defp feature_icon(%{icon: nil} = assigns), do: ~H""

  defp feature_icon(assigns) do
    assigns = assign_new(assigns, :active, fn -> false end)
    feature_icon_for(assigns)
  end

  defp feature_icon_for(%{icon: "ontology"} = assigns) do
    ~H"""
    <svg
      class={["w-[18px] h-[18px]", if(@active, do: "text-[#03b6d4]", else: "text-black/40")]}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <circle cx="12" cy="12" r="3" /><path d="M12 2v4" /><path d="M12 18v4" />
      <path d="M4.93 4.93l2.83 2.83" /><path d="M16.24 16.24l2.83 2.83" />
      <path d="M2 12h4" /><path d="M18 12h4" />
      <path d="M4.93 19.07l2.83-2.83" /><path d="M16.24 7.76l2.83-2.83" />
    </svg>
    """
  end

  defp feature_icon_for(%{icon: "knowledge_gap"} = assigns) do
    ~H"""
    <svg
      class={["w-[18px] h-[18px]", if(@active, do: "text-[#03b6d4]", else: "text-black/40")]}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <line x1="12" y1="3" x2="12" y2="21" />
      <path d="M12 3 L4 5 L4 21 L12 21" />
      <path d="M12 3 L20 5 L20 21 L12 21" stroke-dasharray="3 2" />
      <line x1="6" y1="9" x2="10" y2="9" />
      <line x1="6" y1="12" x2="10" y2="12" />
      <path d="M15 8 Q15 6 16.5 6 Q18 6 18 8 Q18 10 16.5 10.5" />
      <circle cx="16.5" cy="13" r="0.6" fill="currentColor" stroke="none" />
      <line x1="16.5" y1="1" x2="16.5" y2="4" />
      <polyline points="15,3 16.5,4.5 18,3" />
    </svg>
    """
  end

  defp feature_icon_for(%{icon: "knowledge_update"} = assigns) do
    ~H"""
    <svg
      class={["w-[18px] h-[18px]", if(@active, do: "text-[#03b6d4]", else: "text-black/40")]}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M23 4v6h-6" />
      <path d="M1 20v-6h6" />
      <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10" />
      <path d="M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
    </svg>
    """
  end

  defp feature_icon_for(%{icon: "document_update"} = assigns) do
    ~H"""
    <svg
      class={["w-[18px] h-[18px]", if(@active, do: "text-[#03b6d4]", else: "text-black/40")]}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
      <polyline points="14 2 14 8 20 8" />
      <path d="M10 13l-1 4 4-1 5-5-3-3-5 5z" />
    </svg>
    """
  end

  defp feature_icon_for(assigns) do
    ~H"""
    <svg
      class={[
        "w-[18px] h-[18px]",
        if(Map.get(assigns, :active, false), do: "text-[#03b6d4]", else: "text-black/40")
      ]}
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <rect x="3" y="3" width="18" height="18" rx="2" /><path d="M12 8v8M8 12h8" />
    </svg>
    """
  end
end
