defmodule ZaqWeb.Live.BO.System.SystemConfigLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.System.SystemConfigComponents

  alias Zaq.System
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.IngestionConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.TelemetryConfig

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/bo/system-config")
     |> assign(:page_title, "System Configuration")
     |> assign(:active_tab, :telemetry)
     |> assign(:llm_providers, llm_provider_options())
     |> assign(:embedding_providers, embedding_provider_options())
     |> assign(:image_to_text_providers, image_to_text_provider_options())
     |> load_telemetry_form()
     |> load_llm_form()
     |> load_embedding_form()
     |> load_image_to_text_form()
     |> load_ingestion_form()}
  end

  # ── Tab navigation ─────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # ── Telemetry ──────────────────────────────────────────────────────────

  def handle_event("validate_telemetry", %{"telemetry_config" => params}, socket) do
    changeset =
      System.get_telemetry_config()
      |> TelemetryConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :telemetry_form, to_form(changeset, as: :telemetry_config))}
  end

  def handle_event("save_telemetry", %{"telemetry_config" => params}, socket) do
    changeset = TelemetryConfig.changeset(System.get_telemetry_config(), params)

    case System.save_telemetry_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_telemetry_form()
         |> put_flash(:info, "Telemetry settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(
           socket,
           :telemetry_form,
           to_form(Map.put(cs, :action, :validate), as: :telemetry_config)
         )}
    end
  end

  # ── LLM ───────────────────────────────────────────────────────────────

  def handle_event("validate_llm", %{"llm_config" => params}, socket) do
    provider_id = params["provider"] || "custom"
    model_id = params["model"]
    previous_provider = socket.assigns.llm_form[:provider].value
    previous_model = socket.assigns.llm_form[:model].value

    params =
      if provider_id != previous_provider do
        Map.put(params, "endpoint", llm_provider_endpoint(provider_id))
      else
        params
      end

    changeset =
      System.get_llm_config()
      |> LLMConfig.changeset(params)
      |> Map.put(:action, :validate)

    capabilities =
      if provider_id != previous_provider or model_id != previous_model do
        llm_model_capabilities(provider_id, model_id)
      else
        socket.assigns.llm_capabilities
      end

    {:noreply,
     socket
     |> assign(:llm_model_options, llm_model_options(provider_id))
     |> assign(:llm_capabilities, capabilities)
     |> assign(:llm_form, to_form(changeset, as: :llm_config))}
  end

  def handle_event("save_llm", %{"llm_config" => params}, socket) do
    changeset = LLMConfig.changeset(System.get_llm_config(), params)

    case System.save_llm_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_llm_form()
         |> put_flash(:info, "LLM settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket, :llm_form, to_form(Map.put(cs, :action, :validate), as: :llm_config))}
    end
  end

  # ── Embedding ─────────────────────────────────────────────────────────

  def handle_event("validate_embedding", %{"embedding_config" => params}, socket) do
    provider_id = params["provider"] || "custom"
    previous_provider = socket.assigns.embedding_form[:provider].value
    previous_model = socket.assigns.embedding_form[:model].value
    model_id = params["model"]

    params =
      cond do
        provider_id != previous_provider ->
          params
          |> Map.put("endpoint", embedding_provider_endpoint(provider_id))
          |> Map.put("dimension", "")

        model_id != previous_model ->
          case embedding_model_dimension(provider_id, model_id) do
            nil -> params
            dim -> Map.put(params, "dimension", to_string(dim))
          end

        true ->
          params
      end

    changeset =
      System.get_embedding_config()
      |> EmbeddingConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:embedding_model_options, embedding_model_options(provider_id))
     |> assign(:embedding_form, to_form(changeset, as: :embedding_config))}
  end

  def handle_event("save_embedding", %{"embedding_config" => params}, socket) do
    changeset = EmbeddingConfig.changeset(System.get_embedding_config(), params)

    case System.save_embedding_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_embedding_form()
         |> put_flash(:info, "Embedding settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(
           socket,
           :embedding_form,
           to_form(Map.put(cs, :action, :validate), as: :embedding_config)
         )}
    end
  end

  # ── Image to Text ──────────────────────────────────────────────────────

  def handle_event("validate_image_to_text", %{"image_to_text_config" => params}, socket) do
    provider_id = params["provider"] || "custom"
    previous_provider = socket.assigns.image_to_text_form[:provider].value

    params =
      if provider_id != previous_provider do
        Map.put(params, "api_url", image_to_text_provider_endpoint(provider_id))
      else
        params
      end

    changeset =
      System.get_image_to_text_config()
      |> ImageToTextConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:image_to_text_model_options, image_to_text_model_options(provider_id))
     |> assign(:image_to_text_form, to_form(changeset, as: :image_to_text_config))}
  end

  def handle_event("save_image_to_text", %{"image_to_text_config" => params}, socket) do
    changeset = ImageToTextConfig.changeset(System.get_image_to_text_config(), params)

    case System.save_image_to_text_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_image_to_text_form()
         |> put_flash(:info, "Image-to-Text settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(
           socket,
           :image_to_text_form,
           to_form(Map.put(cs, :action, :validate), as: :image_to_text_config)
         )}
    end
  end

  # ── Ingestion ─────────────────────────────────────────────────────────

  def handle_event("validate_ingestion", %{"ingestion_config" => params}, socket) do
    changeset =
      System.get_ingestion_config()
      |> IngestionConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :ingestion_form, to_form(changeset, as: :ingestion_config))}
  end

  def handle_event("save_ingestion", %{"ingestion_config" => params}, socket) do
    changeset = IngestionConfig.changeset(System.get_ingestion_config(), params)

    case System.save_ingestion_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_ingestion_form()
         |> put_flash(:info, "Ingestion settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(
           socket,
           :ingestion_form,
           to_form(Map.put(cs, :action, :validate), as: :ingestion_config)
         )}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp load_telemetry_form(socket) do
    changeset = TelemetryConfig.changeset(System.get_telemetry_config(), %{})
    assign(socket, :telemetry_form, to_form(changeset, as: :telemetry_config))
  end

  defp load_llm_form(socket) do
    cfg = System.get_llm_config()
    provider_id = cfg.provider || "custom"
    changeset = LLMConfig.changeset(%LLMConfig{cfg | api_key: ""}, %{})

    socket
    |> assign(:llm_model_options, llm_model_options(provider_id))
    |> assign(:llm_capabilities, llm_model_capabilities(provider_id, cfg.model))
    |> assign(:llm_api_key_value, cfg.api_key || "")
    |> assign(:llm_form, to_form(changeset, as: :llm_config))
  end

  defp load_embedding_form(socket) do
    cfg = System.get_embedding_config()
    provider_id = cfg.provider || "custom"
    changeset = EmbeddingConfig.changeset(%EmbeddingConfig{cfg | api_key: ""}, %{})

    socket
    |> assign(:embedding_model_options, embedding_model_options(provider_id))
    |> assign(:embedding_api_key_value, cfg.api_key || "")
    |> assign(:embedding_form, to_form(changeset, as: :embedding_config))
  end

  defp load_image_to_text_form(socket) do
    cfg = System.get_image_to_text_config()
    provider_id = cfg.provider || "custom"
    changeset = ImageToTextConfig.changeset(%ImageToTextConfig{cfg | api_key: ""}, %{})

    socket
    |> assign(:image_to_text_model_options, image_to_text_model_options(provider_id))
    |> assign(:image_to_text_api_key_value, cfg.api_key || "")
    |> assign(:image_to_text_form, to_form(changeset, as: :image_to_text_config))
  end

  defp load_ingestion_form(socket) do
    changeset = IngestionConfig.changeset(System.get_ingestion_config(), %{})
    assign(socket, :ingestion_form, to_form(changeset, as: :ingestion_config))
  end

  # Returns %{json_mode: bool | nil, logprobs: bool | nil} from LLMDB for the given model.
  # nil means unknown (no warning shown). false means explicitly not supported (warning shown).
  defp llm_model_capabilities("custom", _), do: %{json_mode: nil, logprobs: nil}
  defp llm_model_capabilities(_, nil), do: %{json_mode: nil, logprobs: nil}
  defp llm_model_capabilities(_, ""), do: %{json_mode: nil, logprobs: nil}

  defp llm_model_capabilities(provider_id, model_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.model(provider_atom, model_id) do
      {:ok, m} ->
        caps = m.capabilities || %{}
        json = Map.get(caps, :json) || %{}
        %{json_mode: Map.get(json, :native), logprobs: nil}

      _ ->
        %{json_mode: nil, logprobs: nil}
    end
  rescue
    ArgumentError -> %{json_mode: nil, logprobs: nil}
  end

  # Returns [{display_name, provider_id_string}] for the provider dropdown.
  # Includes all LLMDB providers that support chat, plus a "Custom" fallback.
  defp llm_provider_options do
    llmdb_options =
      LLMDB.providers()
      |> Enum.reject(& &1.alias_of)
      |> Enum.map(&{&1.name || Atom.to_string(&1.id), Atom.to_string(&1.id)})
      |> Enum.sort_by(&elem(&1, 0))

    llmdb_options ++ [{"Custom", "custom"}]
  end

  # Returns [{model_name, model_id}] for the model dropdown, or [] for custom providers.
  defp llm_model_options("custom"), do: []

  defp llm_model_options(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    LLMDB.models(provider_atom)
    |> Enum.reject(&(&1.deprecated or &1.retired))
    |> Enum.map(&{&1.name || &1.id, &1.id})
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  # Returns the base_url for a provider, or empty string for custom.
  defp llm_provider_endpoint("custom"), do: ""

  defp llm_provider_endpoint(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.provider(provider_atom) do
      {:ok, provider} -> provider.base_url || ""
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end

  # Returns [{display_name, provider_id_string}] for providers with embedding models, plus "Custom".
  defp embedding_provider_options do
    llmdb_options =
      LLMDB.providers()
      |> Enum.reject(& &1.alias_of)
      |> Enum.filter(fn p ->
        LLMDB.models(p.id)
        |> Enum.any?(fn m -> not m.deprecated and not m.retired and embedding_model?(m) end)
      end)
      |> Enum.map(&{&1.name || Atom.to_string(&1.id), Atom.to_string(&1.id)})
      |> Enum.sort_by(&elem(&1, 0))

    llmdb_options ++ [{"Custom", "custom"}]
  end

  # Returns [{model_name, model_id}] filtered to embedding models, or [] for custom.
  defp embedding_model_options("custom"), do: []

  defp embedding_model_options(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    LLMDB.models(provider_atom)
    |> Enum.reject(&(&1.deprecated or &1.retired))
    |> Enum.filter(&embedding_model?/1)
    |> Enum.map(&{&1.name || &1.id, &1.id})
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  @embedding_name_patterns ~w(embed bge e5- gte- nomic rerank)

  defp embedding_model?(m) do
    caps = m.capabilities || %{}
    embeddings = Map.get(caps, :embeddings)

    case embeddings do
      false -> false
      %{} = e when map_size(e) > 0 -> true
      true -> true
      _ -> Enum.any?(@embedding_name_patterns, &String.contains?(m.id, &1))
    end
  end

  # Returns the default dimension for a model, or nil if not available.
  defp embedding_model_dimension("custom", _model_id), do: nil
  defp embedding_model_dimension(_provider_id, nil), do: nil
  defp embedding_model_dimension(_provider_id, ""), do: nil

  defp embedding_model_dimension(provider_id, model_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.model(provider_atom, model_id) do
      {:ok, %{capabilities: %{embeddings: %{default_dimensions: d}}}} when is_integer(d) -> d
      {:ok, %{capabilities: %{embeddings: %{max_dimensions: d}}}} when is_integer(d) -> d
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Returns the base_url for an embedding provider, or empty string for custom.
  defp embedding_provider_endpoint("custom"), do: ""

  defp embedding_provider_endpoint(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.provider(provider_atom) do
      {:ok, provider} -> provider.base_url || ""
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end

  # Returns [{display_name, provider_id_string}] for providers that have at least
  # one non-deprecated, non-retired model supporting image input, plus "Custom".
  defp image_to_text_provider_options do
    llmdb_options =
      LLMDB.providers()
      |> Enum.reject(& &1.alias_of)
      |> Enum.filter(fn p ->
        LLMDB.models(p.id)
        |> Enum.any?(fn m ->
          input = (m.modalities && m.modalities.input) || []
          not m.deprecated and not m.retired and :image in input
        end)
      end)
      |> Enum.map(&{&1.name || Atom.to_string(&1.id), Atom.to_string(&1.id)})
      |> Enum.sort_by(&elem(&1, 0))

    llmdb_options ++ [{"Custom", "custom"}]
  end

  # Returns [{model_name, model_id}] filtered to models with image input, or [] for custom.
  defp image_to_text_model_options("custom"), do: []

  defp image_to_text_model_options(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    LLMDB.models(provider_atom)
    |> Enum.reject(&(&1.deprecated or &1.retired))
    |> Enum.filter(fn m ->
      input = (m.modalities && m.modalities.input) || []
      :image in input
    end)
    |> Enum.map(&{&1.name || &1.id, &1.id})
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  # Returns the base_url for an image-to-text provider, or empty string for custom.
  defp image_to_text_provider_endpoint("custom"), do: ""

  defp image_to_text_provider_endpoint(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.provider(provider_atom) do
      {:ok, provider} -> provider.base_url || ""
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end
end
