defmodule ZaqWeb.Live.BO.System.LicenseLive do
  use ZaqWeb, :live_view

  alias Zaq.License.{FeatureStore, Loader}

  @zaq_features [
    %{
      name: "Ontology Management",
      description:
        "Build and manage your organization's knowledge graph with automated entity extraction and relationship mapping.",
      icon: "ontology"
    },
    %{
      name: "Knowledge Gap Detection",
      description:
        "Automatically identify missing information and suggest content that should be added to your knowledge base.",
      icon: "knowledge_gap"
    },
    %{
      name: "Slack Integration",
      description:
        "Connect ZAQ to your Slack workspace. Your team can ask questions and get cited answers directly in channels.",
      icon: "slack"
    },
    %{
      name: "Email Channel",
      description:
        "Process incoming emails and route them through ZAQ's AI engine for automated triage and response drafting.",
      icon: "email"
    },
    %{
      name: "Advanced RAG Pipeline",
      description:
        "Enhanced retrieval-augmented generation with hybrid search, re-ranking, and multi-hop reasoning.",
      icon: "rag"
    },
    %{
      name: "Multi-Tenant Sessions",
      description:
        "Isolate knowledge access per team or department with fine-grained session and permission controls.",
      icon: "sessions"
    }
  ]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "license:updated")
    end

    {:ok,
     socket
     |> assign_license_state()
     |> assign(current_path: "/bo/license", upload_error: nil)
     |> allow_upload(:license_file, accept: ~w(.zaq-license), max_entries: 1)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_license", _params, socket) do
    result =
      consume_uploaded_entries(socket, :license_file, fn %{path: tmp_path}, entry ->
        dest_dir = Application.app_dir(:zaq, "priv/licenses")
        File.mkdir_p!(dest_dir)
        dest = Path.join(dest_dir, entry.client_name)
        File.cp!(tmp_path, dest)

        case Loader.load(dest) do
          {:ok, _license_data} -> {:ok, :loaded}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case result do
      [:loaded] ->
        {:noreply, socket |> assign_license_state() |> assign(upload_error: nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, upload_error: format_upload_error(reason))}

      [] ->
        {:noreply, assign(socket, upload_error: "No file selected.")}
    end
  end

  def handle_info(:license_updated, socket) do
    {:noreply, assign_license_state(socket)}
  end

  defp assign_license_state(socket) do
    license_data = FeatureStore.license_data()
    loaded_modules = FeatureStore.loaded_modules()

    licensed_names =
      case license_data do
        nil -> []
        data -> data |> Map.get("features", []) |> Enum.map(& &1["name"])
      end

    locked_features = Enum.reject(@zaq_features, fn f -> f.name in licensed_names end)

    assign(socket,
      license_data: license_data,
      loaded_modules: loaded_modules,
      zaq_features: @zaq_features,
      locked_features: locked_features
    )
  end

  def upload_entry_error(:too_large), do: "File is too large."
  def upload_entry_error(:not_accepted), do: "Only .zaq-license files are accepted."
  def upload_entry_error(:too_many_files), do: "Only one file at a time."
  def upload_entry_error(_), do: "Upload failed."

  defp format_upload_error(:license_expired), do: "This license has expired."

  defp format_upload_error(:missing_license_dat),
    do: "Invalid license file: missing license data."

  defp format_upload_error(:invalid_payload_json), do: "Invalid license file: malformed payload."
  defp format_upload_error(:invalid_license_dat_format), do: "Invalid license file format."
  defp format_upload_error({:extract_failed, _}), do: "Could not read license file."
  defp format_upload_error(reason), do: "Failed to load license: #{inspect(reason)}"

  defp days_left(nil), do: nil

  defp days_left(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now(), :day)
      _ -> nil
    end
  end

  defp feature_icon(%{icon: "ontology"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <circle cx="12" cy="5" r="3" /><circle cx="5" cy="19" r="3" /><circle cx="19" cy="19" r="3" />
      <path d="M12 8v3M9.5 16.5L7 17M14.5 16.5L17 17" />
    </svg>
    """
  end

  defp feature_icon(%{icon: "knowledge_gap"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <circle cx="12" cy="12" r="10" /><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3" /><line
        x1="12"
        y1="17"
        x2="12.01"
        y2="17"
      />
    </svg>
    """
  end

  defp feature_icon(%{icon: "slack"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path d="M14.5 10c-.83 0-1.5-.67-1.5-1.5v-5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5v5c0 .83-.67 1.5-1.5 1.5z" />
      <path d="M20.5 10H19V8.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z" />
      <path d="M9.5 14c.83 0 1.5.67 1.5 1.5v5c0 .83-.67 1.5-1.5 1.5S8 21.33 8 20.5v-5c0-.83.67-1.5 1.5-1.5z" />
      <path d="M3.5 14H5v1.5c0 .83-.67 1.5-1.5 1.5S2 16.33 2 15.5 2.67 14 3.5 14z" />
      <path d="M14 14.5c0-.83.67-1.5 1.5-1.5h5c.83 0 1.5.67 1.5 1.5s-.67 1.5-1.5 1.5h-5c-.83 0-1.5-.67-1.5-1.5z" />
      <path d="M14 20.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5-.67 1.5-1.5 1.5-1.5-.67-1.5-1.5z" />
      <path d="M10 9.5C10 8.67 9.33 8 8.5 8h-5C2.67 8 2 8.67 2 9.5S2.67 11 3.5 11h5c.83 0 1.5-.67 1.5-1.5z" />
    </svg>
    """
  end

  defp feature_icon(%{icon: "email"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <rect x="2" y="4" width="20" height="16" rx="2" /><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
    </svg>
    """
  end

  defp feature_icon(%{icon: "rag"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
      <polyline points="3.27 6.96 12 12.01 20.73 6.96" /><line x1="12" y1="22.08" x2="12" y2="12" />
    </svg>
    """
  end

  defp feature_icon(%{icon: "sessions"} = assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" />
      <path d="M23 21v-2a4 4 0 0 0-3-3.87" /><path d="M16 3.13a4 4 0 0 1 0 7.75" />
    </svg>
    """
  end

  defp feature_icon(assigns) do
    ~H"""
    <svg
      class="w-[18px] h-[18px] text-black/40"
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
