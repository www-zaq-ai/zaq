defmodule ZaqWeb.Live.BO.System.SystemConfigLive do
  use ZaqWeb, :live_view

  alias Zaq.Agent.MCP
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.TelemetryConfig
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/bo/system-config")
     |> assign(:page_title, "System Configuration")
     |> assign(:active_tab, :telemetry)
     |> assign(:ai_credential_modal, false)
     |> assign(:ai_credential_delete_confirm_modal, false)
     |> assign(:ai_credential_action, :new)
     |> assign(:ai_credential_id, nil)
     |> assign(:embedding_unlock_modal, false)
     |> assign(:embedding_save_confirm_modal, false)
     |> assign(:pending_embedding_params, nil)
     |> assign(:mcp_endpoint_modal, false)
     |> assign(:mcp_endpoint_delete_confirm_modal, false)
     |> assign(:mcp_endpoint_action, :new)
     |> assign(:mcp_endpoint_id, nil)
     |> assign(:mcp_filter_name, "")
     |> assign(:mcp_filter_type, "all")
     |> assign(:mcp_filter_status, "all")
     |> assign(:mcp_page, 1)
     |> assign(:mcp_per_page, 20)
     |> assign(:global_agent_options, global_agent_options())
     |> assign(:global_default_agent_id, engine_get_global_default_agent_id())
     |> assign(:ai_provider_options, provider_options(fn _ -> true end))
     |> assign(:connect_grants_modal, false)
     |> assign(:connect_credential_modal, false)
     |> assign(:connect_credential_action, :edit)
     |> assign(:connect_credential_changeset, nil)
     |> assign(:connect_credential_form, nil)
     |> assign(:connect_credential_errors, [])
     |> assign(:selected_connect_credential, nil)
     |> assign(:selected_connect_grants, [])
     |> assign(:selected_connect_refresh_schedule, %{})
     |> load_ai_credential_form()
     |> load_ai_credentials()
     |> load_connect_credentials()
     |> load_mcp_endpoint_form()
     |> load_mcp_endpoints()
     |> load_telemetry_form()
     |> load_llm_form()
     |> load_embedding_form()
     |> load_image_to_text_form()}
  end

  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ~w(ai_credentials auth_credentials mcps agents llm embedding image_to_text telemetry) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :active_tab, :telemetry)}
  end

  # ── Tab navigation ─────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/bo/system-config?tab=#{tab}")}
  end

  def handle_event("open_connect_grants", %{"id" => id}, socket) do
    credential =
      Enum.find(socket.assigns.connect_credentials, &(to_string(&1.id) == to_string(id)))

    {:noreply,
     socket
     |> assign(:selected_connect_credential, credential)
     |> reload_selected_connect_grants(credential)
     |> assign(:connect_grants_modal, true)}
  end

  def handle_event("edit_connect_credential", %{"id" => id}, socket) do
    case engine_connect_fetch_credential(id) do
      {:ok, credential} ->
        changeset = engine_connect_change_credential(credential, %{})

        {:noreply,
         socket
         |> assign(:connect_credential_action, :edit)
         |> assign(:connect_credential_changeset, changeset)
         |> assign(:connect_credential_form, to_form(changeset, as: :credential))
         |> assign(:connect_credential_errors, [])
         |> assign(:connect_credential_modal, true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Credential not found.")}
    end
  end

  def handle_event("close_connect_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:connect_credential_modal, false)
     |> assign(:connect_credential_changeset, nil)
     |> assign(:connect_credential_form, nil)
     |> assign(:connect_credential_errors, [])}
  end

  def handle_event("validate_connect_credential", %{"credential" => params}, socket) do
    credential = socket.assigns.connect_credential_changeset.data

    changeset =
      credential
      |> engine_connect_change_credential(sanitize_connect_credential_params(params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:connect_credential_changeset, changeset)
     |> assign(:connect_credential_form, to_form(changeset, as: :credential))
     |> assign(:connect_credential_errors, format_errors(changeset))}
  end

  def handle_event("save_connect_credential", %{"credential" => params}, socket) do
    credential = socket.assigns.connect_credential_changeset.data

    case engine_connect_update_credential(credential, sanitize_connect_credential_params(params)) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:connect_credential_modal, false)
         |> assign(:connect_credential_changeset, nil)
         |> assign(:connect_credential_form, nil)
         |> assign(:connect_credential_errors, [])
         |> load_connect_credentials()
         |> put_flash(:info, "Credential updated.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:connect_credential_changeset, changeset)
         |> assign(:connect_credential_form, to_form(changeset, as: :credential))
         |> assign(:connect_credential_errors, format_errors(changeset))}
    end
  end

  def handle_event("close_connect_grants_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:connect_grants_modal, false)
     |> assign(:selected_connect_credential, nil)
     |> assign(:selected_connect_grants, [])
     |> assign(:selected_connect_refresh_schedule, %{})}
  end

  def handle_event("delete_connect_grant", %{"id" => id}, socket) do
    credential = socket.assigns.selected_connect_credential

    case Enum.find(socket.assigns.selected_connect_grants, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, put_flash(socket, :error, "Grant not found.")}

      grant ->
        case engine_connect_delete_grant(grant) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Grant erased.")
             |> reload_selected_connect_grants(credential)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Unable to erase grant.")}
        end
    end
  end

  def handle_event("trigger_connect_grant_refresh", %{"id" => id}, socket) do
    credential = socket.assigns.selected_connect_credential

    case Enum.find(socket.assigns.selected_connect_grants, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, put_flash(socket, :error, "Grant not found.")}

      grant ->
        case engine_connect_schedule_refresh(grant) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, "Grant refresh queued.")
             |> reload_selected_connect_grants(credential)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Unable to queue grant refresh.")}
        end
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────────

  def handle_event("validate_telemetry", %{"telemetry_config" => params}, socket) do
    changeset =
      engine_get_telemetry_config()
      |> TelemetryConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :telemetry_form, to_form(changeset, as: :telemetry_config))}
  end

  def handle_event("save_telemetry", %{"telemetry_config" => params}, socket) do
    changeset = TelemetryConfig.changeset(engine_get_telemetry_config(), params)

    case engine_save_telemetry_config(changeset) do
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

  def handle_event("save_global_default_agent", %{"global_default_agent_id" => raw_id}, socket) do
    case engine_set_global_default_agent_id(ParseUtils.parse_optional_int(raw_id)) do
      :ok ->
        {:noreply,
         socket
         |> assign(:global_default_agent_id, engine_get_global_default_agent_id())
         |> put_flash(:info, "Global default agent saved.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to save global default agent: #{inspect(reason)}")}
    end
  end

  # ── LLM ───────────────────────────────────────────────────────────────

  def handle_event("validate_llm", %{"llm_config" => params}, socket) do
    credential_id = params["credential_id"]
    provider_id = provider_from_credential_id(credential_id)
    model_id = params["model"]
    previous_provider = provider_from_credential_id(socket.assigns.llm_form[:credential_id].value)
    previous_model = socket.assigns.llm_form[:model].value

    params =
      if provider_id != previous_provider do
        Map.put(params, "path", llm_provider_path(provider_id, model_id))
      else
        params
      end

    prev_bm25 = to_string(socket.assigns.llm_form[:fusion_bm25_weight].value)
    prev_vector = to_string(socket.assigns.llm_form[:fusion_vector_weight].value)

    params =
      cond do
        params["fusion_bm25_weight"] != prev_bm25 ->
          w = clamp_weight(params["fusion_bm25_weight"])

          params
          |> Map.put("fusion_bm25_weight", w)
          |> Map.put("fusion_vector_weight", Float.round(1.0 - w, 2))

        params["fusion_vector_weight"] != prev_vector ->
          w = clamp_weight(params["fusion_vector_weight"])

          params
          |> Map.put("fusion_vector_weight", w)
          |> Map.put("fusion_bm25_weight", Float.round(1.0 - w, 2))

        true ->
          params
      end

    changeset =
      engine_get_llm_config()
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
    changeset = LLMConfig.changeset(engine_get_llm_config(), params)

    case engine_save_llm_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_llm_form()
         |> put_flash(:info, "LLM settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(:llm_form, to_form(Map.put(cs, :action, :validate), as: :llm_config))}
    end
  end

  # ── Embedding ─────────────────────────────────────────────────────────

  def handle_event("unlock_embedding", _params, socket) do
    {:noreply, assign(socket, :embedding_unlock_modal, true)}
  end

  def handle_event("cancel_unlock_embedding", _params, socket) do
    {:noreply, assign(socket, :embedding_unlock_modal, false)}
  end

  def handle_event("confirm_unlock_embedding", _params, socket) do
    {:noreply,
     socket
     |> assign(:embedding_locked, false)
     |> assign(:embedding_unlock_modal, false)
     |> assign(:embedding_credential_options, credential_options())}
  end

  def handle_event("validate_embedding", %{"embedding_config" => params}, socket) do
    provider_id = provider_from_credential_id(params["credential_id"])

    previous_provider =
      provider_from_credential_id(socket.assigns.embedding_form[:credential_id].value)

    previous_model = socket.assigns.embedding_form[:model].value

    params = adjust_embedding_params(params, provider_id, previous_provider, previous_model)

    changeset =
      engine_get_embedding_config()
      |> EmbeddingConfig.changeset(params)
      |> Map.put(:action, :validate)

    model_changed =
      embedding_model_changed?(params, socket.assigns.saved_model, socket.assigns.saved_dimension)

    {:noreply,
     socket
     |> assign(:embedding_model_options, embedding_model_options(provider_id))
     |> assign(:model_changed, model_changed)
     |> assign(:embedding_form, to_form(changeset, as: :embedding_config))}
  end

  def handle_event("save_embedding", %{"embedding_config" => params}, socket) do
    if socket.assigns.model_changed do
      {:noreply,
       socket
       |> assign(:embedding_save_confirm_modal, true)
       |> assign(:pending_embedding_params, params)}
    else
      do_save_embedding(socket, params)
    end
  end

  def handle_event("cancel_save_embedding", _params, socket) do
    {:noreply, assign(socket, :embedding_save_confirm_modal, false)}
  end

  def handle_event("confirm_save_embedding", _params, socket) do
    do_save_embedding(
      assign(socket, :embedding_save_confirm_modal, false),
      socket.assigns.pending_embedding_params
    )
  rescue
    e ->
      {:noreply,
       socket
       |> assign(:embedding_save_confirm_modal, false)
       |> put_flash(:error, "Failed to apply embedding settings: #{Exception.message(e)}")}
  end

  # ── Image to Text ──────────────────────────────────────────────────────

  def handle_event("validate_image_to_text", %{"image_to_text_config" => params}, socket) do
    provider_id = provider_from_credential_id(params["credential_id"])

    changeset =
      engine_get_image_to_text_config()
      |> ImageToTextConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:image_to_text_model_options, image_to_text_model_options(provider_id))
     |> assign(:image_to_text_form, to_form(changeset, as: :image_to_text_config))}
  end

  def handle_event("save_image_to_text", %{"image_to_text_config" => params}, socket) do
    changeset = ImageToTextConfig.changeset(engine_get_image_to_text_config(), params)

    case engine_save_image_to_text_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_image_to_text_form()
         |> put_flash(:info, "Image-to-Text settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(
           :image_to_text_form,
           to_form(Map.put(cs, :action, :validate), as: :image_to_text_config)
         )}
    end
  end

  # ── AI Credentials ─────────────────────────────────────────────────────

  def handle_event("new_ai_credential", _params, socket) do
    {:noreply,
     socket
     |> assign(:ai_credential_action, :new)
     |> assign(:ai_credential_id, nil)
     |> assign(:ai_credential_modal, true)
     |> load_ai_credential_form()}
  end

  def handle_event("edit_ai_credential", %{"id" => id}, socket) do
    credential = engine_get_ai_provider_credential!(id)

    {:noreply,
     socket
     |> assign(:ai_credential_action, :edit)
     |> assign(:ai_credential_id, credential.id)
     |> assign(:ai_credential_modal, true)
     |> assign(
       :ai_credential_form,
       credential
       |> engine_change_ai_provider_credential(%{})
       |> to_form(as: :ai_credential)
     )}
  end

  def handle_event("close_ai_credential_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:ai_credential_modal, false)
     |> assign(:ai_credential_delete_confirm_modal, false)}
  end

  def handle_event("open_delete_ai_credential_confirm", _params, socket) do
    {:noreply, assign(socket, :ai_credential_delete_confirm_modal, true)}
  end

  def handle_event("cancel_delete_ai_credential", _params, socket) do
    {:noreply, assign(socket, :ai_credential_delete_confirm_modal, false)}
  end

  def handle_event("confirm_delete_ai_credential", _params, socket) do
    result =
      socket.assigns.ai_credential_id
      |> engine_get_ai_provider_credential!()
      |> engine_delete_ai_provider_credential()

    case result do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> assign(:ai_credential_delete_confirm_modal, false)
         |> assign(:ai_credential_modal, false)
         |> load_ai_credentials()
         |> load_llm_form()
         |> load_embedding_form()
         |> load_image_to_text_form()
         |> put_flash(:info, "AI credential deleted.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:ai_credential_delete_confirm_modal, false)
         |> assign(
           :ai_credential_form,
           to_form(Map.put(changeset, :action, :validate), as: :ai_credential)
         )}
    end
  end

  def handle_event("validate_ai_credential", %{"ai_credential" => params}, socket) do
    previous_provider = socket.assigns.ai_credential_form[:provider].value

    params =
      if params["provider"] != previous_provider do
        Map.put(params, "endpoint", provider_endpoint(params["provider"]))
      else
        params
      end

    changeset =
      socket.assigns.ai_credential_action
      |> ai_credential_for_action(socket.assigns.ai_credential_id)
      |> engine_change_ai_provider_credential(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :ai_credential_form, to_form(changeset, as: :ai_credential))}
  end

  def handle_event("save_ai_credential", %{"ai_credential" => params}, socket) do
    result =
      case socket.assigns.ai_credential_action do
        :edit ->
          socket.assigns.ai_credential_id
          |> engine_get_ai_provider_credential!()
          |> engine_update_ai_provider_credential(params)

        _ ->
          engine_create_ai_provider_credential(params)
      end

    case result do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> assign(:ai_credential_modal, false)
         |> load_ai_credentials()
         |> load_llm_form()
         |> load_embedding_form()
         |> load_image_to_text_form()
         |> put_flash(:info, "AI credential saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :ai_credential_form,
           to_form(Map.put(changeset, :action, :validate), as: :ai_credential)
         )}
    end
  end

  # ── MCP Administration ──────────────────────────────────────────────────

  def handle_event("filter_mcp_endpoints", params, socket) do
    {:noreply,
     socket
     |> assign(:mcp_filter_name, Map.get(params, "mcp_filter_name", ""))
     |> assign(:mcp_filter_type, Map.get(params, "mcp_filter_type", "all"))
     |> assign(:mcp_filter_status, Map.get(params, "mcp_filter_status", "all"))
     |> assign(:mcp_page, 1)
     |> load_mcp_endpoints()}
  end

  def handle_event("change_mcp_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:mcp_page, ParseUtils.parse_int(page, socket.assigns.mcp_page))
     |> load_mcp_endpoints()}
  end

  def handle_event("new_mcp_endpoint", _params, socket) do
    {:noreply,
     socket
     |> assign(:mcp_endpoint_action, :new)
     |> assign(:mcp_endpoint_id, nil)
     |> assign(:mcp_endpoint_delete_confirm_modal, false)
     |> assign(:mcp_endpoint_modal, true)
     |> load_mcp_endpoint_form()}
  end

  def handle_event("edit_mcp_endpoint", %{"id" => id}, socket) do
    endpoint = agent_get_mcp_endpoint!(id)

    {:noreply,
     socket
     |> assign(:mcp_endpoint_action, :edit)
     |> assign(:mcp_endpoint_id, endpoint.id)
     |> assign(:mcp_endpoint_delete_confirm_modal, false)
     |> assign(:mcp_endpoint_modal, true)
     |> assign(
       :mcp_endpoint_form,
       to_form(agent_change_mcp_endpoint(endpoint), as: :mcp_endpoint)
     )
     |> assign(:mcp_endpoint_rows, mcp_rows(endpoint))}
  end

  def handle_event("close_mcp_endpoint_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:mcp_endpoint_modal, false)
     |> assign(:mcp_endpoint_delete_confirm_modal, false)}
  end

  def handle_event("open_delete_mcp_endpoint_confirm", _params, socket) do
    {:noreply, assign(socket, :mcp_endpoint_delete_confirm_modal, true)}
  end

  def handle_event("cancel_delete_mcp_endpoint", _params, socket) do
    {:noreply, assign(socket, :mcp_endpoint_delete_confirm_modal, false)}
  end

  def handle_event("confirm_delete_mcp_endpoint", _params, socket) do
    event =
      Event.new(%{action: :delete, id: socket.assigns.mcp_endpoint_id}, :agent,
        opts: [action: :mcp_endpoint_updated]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, %{endpoint: endpoint} = payload} ->
        socket =
          socket
          |> assign(:mcp_endpoint_delete_confirm_modal, false)
          |> assign(:mcp_endpoint_modal, false)
          |> load_mcp_endpoints()
          |> put_flash(:info, "MCP endpoint deleted (#{endpoint.name}).")
          |> maybe_put_mcp_runtime_warnings(payload)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:mcp_endpoint_delete_confirm_modal, false)
         |> assign(
           :mcp_endpoint_form,
           to_form(Map.put(changeset, :action, :validate), as: :mcp_endpoint)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:mcp_endpoint_delete_confirm_modal, false)
         |> put_flash(:error, "Failed to delete MCP endpoint: #{inspect(reason)}")}

      other ->
        {:noreply,
         socket
         |> assign(:mcp_endpoint_delete_confirm_modal, false)
         |> put_flash(:error, "Failed to delete MCP endpoint: #{inspect(other)}")}
    end
  end

  def handle_event("enable_predefined_mcp", %{"predefined_id" => predefined_id}, socket) do
    event =
      Event.new(%{action: :enable_predefined, predefined_id: predefined_id}, :agent,
        opts: [action: :mcp_endpoint_updated]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, %{endpoint: endpoint} = payload} ->
        socket =
          socket
          |> load_mcp_endpoints()
          |> put_flash(:info, "Predefined MCP enabled.")
          |> maybe_put_mcp_runtime_warnings(payload)

        predefined =
          endpoint.predefined_id && agent_mcp_predefined_catalog()[endpoint.predefined_id]

        socket =
          if is_map(predefined) and predefined[:editable] do
            socket
            |> assign(:mcp_endpoint_action, :edit)
            |> assign(:mcp_endpoint_id, endpoint.id)
            |> assign(:mcp_endpoint_modal, true)
            |> assign(:mcp_endpoint_delete_confirm_modal, false)
            |> assign(
              :mcp_endpoint_form,
              to_form(agent_change_mcp_endpoint(endpoint), as: :mcp_endpoint)
            )
            |> assign(:mcp_endpoint_rows, mcp_rows(endpoint))
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enable MCP: #{inspect(reason)}")}

      other ->
        {:noreply, put_flash(socket, :error, "Failed to enable MCP: #{inspect(other)}")}
    end
  end

  def handle_event("validate_mcp_endpoint", %{"mcp_endpoint" => params}, socket) do
    {rows, parsed} = build_mcp_endpoint_payload(params, socket.assigns.mcp_endpoint_rows)

    changeset =
      socket.assigns.mcp_endpoint_action
      |> mcp_endpoint_for_action(socket.assigns.mcp_endpoint_id)
      |> agent_change_mcp_endpoint(parsed)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:mcp_endpoint_form, to_form(changeset, as: :mcp_endpoint))
     |> assign(:mcp_endpoint_rows, rows)}
  end

  def handle_event("save_mcp_endpoint", %{"mcp_endpoint" => params}, socket) do
    {rows, parsed} = build_mcp_endpoint_payload(params, socket.assigns.mcp_endpoint_rows)

    request =
      case socket.assigns.mcp_endpoint_action do
        :edit ->
          %{action: :update, id: socket.assigns.mcp_endpoint_id, attrs: parsed}

        _ ->
          %{action: :create, attrs: parsed}
      end

    event =
      Event.new(request, :agent, opts: [action: :mcp_endpoint_updated])

    result = NodeRouter.dispatch(event).response

    case result do
      {:ok, %{endpoint: endpoint} = payload} ->
        socket =
          socket
          |> assign(:mcp_endpoint_modal, false)
          |> load_mcp_endpoints()
          |> put_flash(:info, "MCP endpoint saved (#{endpoint.name}).")
          |> maybe_put_mcp_runtime_warnings(payload)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :mcp_endpoint_form,
           to_form(Map.put(changeset, :action, :validate), as: :mcp_endpoint)
         )
         |> assign(:mcp_endpoint_rows, rows)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:mcp_endpoint_rows, rows)
         |> put_flash(:error, "Failed to save MCP endpoint: #{inspect(reason)}")}

      other ->
        {:noreply,
         socket
         |> assign(:mcp_endpoint_rows, rows)
         |> put_flash(:error, "Failed to save MCP endpoint: #{inspect(other)}")}
    end
  end

  def handle_event("add_mcp_row", %{"collection" => collection}, socket) do
    {:noreply,
     assign(socket, :mcp_endpoint_rows, add_mcp_row(socket.assigns.mcp_endpoint_rows, collection))}
  end

  def handle_event("remove_mcp_row", %{"collection" => collection, "index" => index}, socket) do
    {:noreply,
     assign(
       socket,
       :mcp_endpoint_rows,
       remove_mcp_row(
         socket.assigns.mcp_endpoint_rows,
         collection,
         ParseUtils.parse_int(index, 0)
       )
     )}
  end

  def handle_event("test_mcp_endpoint", %{"id" => id}, socket) do
    endpoint_id = ParseUtils.parse_optional_int(id)

    event =
      Event.new(%{endpoint_id: endpoint_id}, :agent,
        opts: [
          action: :mcp_test_list_tools,
          mcp_module: mcp_module(),
          mcp_test_opts: [timeout: 5000]
        ]
      )

    result = NodeRouter.dispatch(event)

    case result.response do
      {:ok, _payload} ->
        {:noreply, put_flash(socket, :info, "MCP tools test succeeded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mcp_test_failure_message(reason))}

      other ->
        {:noreply, put_flash(socket, :error, "MCP tools test returned: #{inspect(other)}")}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_save_embedding(socket, params) do
    changeset = EmbeddingConfig.changeset(engine_get_embedding_config(), params)

    case engine_save_embedding_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:pending_embedding_params, nil)
         |> load_embedding_form()
         |> put_flash(:info, "Embedding settings saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(
           :embedding_form,
           to_form(Map.put(cs, :action, :validate), as: :embedding_config)
         )}
    end
  end

  defp load_telemetry_form(socket) do
    changeset = TelemetryConfig.changeset(engine_get_telemetry_config(), %{})
    assign(socket, :telemetry_form, to_form(changeset, as: :telemetry_config))
  end

  defp load_ai_credentials(socket) do
    assign(socket, :ai_credentials, engine_list_ai_provider_credentials())
  end

  defp load_connect_credentials(socket) do
    assign(socket, :connect_credentials, engine_connect_list_credentials())
  end

  defp load_ai_credential_form(socket) do
    changeset = engine_change_ai_provider_credential(%Zaq.System.AIProviderCredential{}, %{})
    assign(socket, :ai_credential_form, to_form(changeset, as: :ai_credential))
  end

  defp load_mcp_endpoints(socket) do
    filters = %{
      "name" => socket.assigns.mcp_filter_name,
      "type" => socket.assigns.mcp_filter_type,
      "status" => socket.assigns.mcp_filter_status
    }

    {entries, total} =
      agent_filter_mcp_endpoints(filters,
        page: socket.assigns.mcp_page,
        per_page: socket.assigns.mcp_per_page
      )

    socket
    |> assign(:mcp_endpoints, entries)
    |> assign(:mcp_total_count, total)
  end

  defp load_mcp_endpoint_form(socket) do
    changeset =
      agent_change_mcp_endpoint(%MCP.Endpoint{}, %{
        "type" => "local",
        "status" => "disabled",
        "timeout_ms" => 5000
      })

    socket
    |> assign(:mcp_endpoint_form, to_form(changeset, as: :mcp_endpoint))
    |> assign(:mcp_endpoint_rows, mcp_rows(%MCP.Endpoint{}))
  end

  defp mcp_endpoint_for_action(:edit, id), do: agent_get_mcp_endpoint!(id)
  defp mcp_endpoint_for_action(_, _), do: %MCP.Endpoint{}

  defp build_mcp_endpoint_payload(params, rows_state) do
    rows = mcp_rows_from_params(params, rows_state)
    parsed = parse_mcp_endpoint_params(params, rows)
    {rows, parsed}
  end

  defp mcp_rows(endpoint) do
    %{
      args: list_to_rows(endpoint.args || []),
      headers: map_to_rows(endpoint.headers || %{}),
      secret_headers: secret_map_to_rows(endpoint.secret_headers || %{}),
      environments: map_to_rows(endpoint.environments || %{}),
      secret_environments: secret_map_to_rows(endpoint.secret_environments || %{}),
      settings: Jason.encode!(endpoint.settings || %{})
    }
  end

  defp mcp_rows_from_params(params, fallback_rows) do
    %{
      args:
        rows_from_params(
          Map.get(params, "args_rows"),
          Map.get(fallback_rows, :args, [blank_arg_row()])
        ),
      headers:
        rows_from_params(
          Map.get(params, "headers_rows"),
          Map.get(fallback_rows, :headers, [blank_kv_row()])
        ),
      secret_headers:
        rows_from_params(
          Map.get(params, "secret_headers_rows"),
          Map.get(fallback_rows, :secret_headers, [blank_kv_row()])
        ),
      environments:
        rows_from_params(
          Map.get(params, "environments_rows"),
          Map.get(fallback_rows, :environments, [blank_kv_row()])
        ),
      secret_environments:
        rows_from_params(
          Map.get(params, "secret_environments_rows"),
          Map.get(fallback_rows, :secret_environments, [blank_kv_row()])
        ),
      settings: Map.get(params, "settings_text", Map.get(fallback_rows, :settings, "{}"))
    }
  end

  defp parse_mcp_endpoint_params(params, rows) do
    type = Map.get(params, "type", "local")

    base = %{
      "name" => Map.get(params, "name", ""),
      "type" => type,
      "status" => Map.get(params, "status", "disabled"),
      "timeout_ms" => Map.get(params, "timeout_ms", "5000"),
      "command" => blank_to_nil(Map.get(params, "command", "")),
      "url" => blank_to_nil(Map.get(params, "url", "")),
      "predefined_id" => blank_to_nil(Map.get(params, "predefined_id", "")),
      "args" => parse_arg_rows(Map.get(rows, :args, [])),
      "headers" => parse_kv_rows(Map.get(rows, :headers, [])),
      "secret_headers" => parse_kv_rows(Map.get(rows, :secret_headers, [])),
      "environments" => parse_kv_rows(Map.get(rows, :environments, [])),
      "secret_environments" => parse_kv_rows(Map.get(rows, :secret_environments, [])),
      "settings" => parse_json_map(Map.get(rows, :settings, "{}"))
    }

    apply_mcp_type_scope(base, type)
  end

  defp parse_json_map(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        %{}

      text ->
        case Jason.decode(text) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end
    end
  end

  defp parse_json_map(_), do: %{}

  defp parse_arg_rows(rows) do
    rows
    |> Enum.map(fn row -> row["value"] || row[:value] || "" end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_kv_rows(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      key = row["key"] || row[:key] || ""
      value = row["value"] || row[:value] || ""
      key = String.trim(key)
      value = String.trim(value)

      if key == "" do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp rows_from_params(nil, fallback), do: normalize_rows(fallback)

  defp rows_from_params(rows_map, fallback) when is_map(rows_map) do
    rows =
      rows_map
      |> Enum.sort_by(fn {idx, _} -> ParseUtils.parse_int(idx, 0) end)
      |> Enum.map(fn {_idx, row} ->
        %{
          "key" => Map.get(row, "key", ""),
          "value" => Map.get(row, "value", "")
        }
      end)

    normalize_rows(if rows == [], do: fallback, else: rows)
  end

  defp rows_from_params(_other, fallback), do: normalize_rows(fallback)

  defp normalize_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        "key" => row["key"] || row[:key] || "",
        "value" => row["value"] || row[:value] || ""
      }
    end)
    |> case do
      [] -> [%{"key" => "", "value" => ""}]
      list -> list
    end
  end

  defp normalize_rows(_), do: [%{"key" => "", "value" => ""}]

  defp list_to_rows(list) when is_list(list) do
    rows = Enum.map(list, &%{"key" => "", "value" => &1})
    if rows == [], do: [blank_arg_row()], else: rows
  end

  defp list_to_rows(_), do: [blank_arg_row()]

  defp map_to_rows(map) when is_map(map) do
    rows = Enum.map(map, fn {k, v} -> %{"key" => k, "value" => v} end)
    if rows == [], do: [blank_kv_row()], else: rows
  end

  defp map_to_rows(_), do: [blank_kv_row()]

  defp secret_map_to_rows(map) when is_map(map) do
    rows =
      Enum.map(map, fn {k, v} ->
        %{"key" => k, "value" => decrypt_secret_for_form(v)}
      end)

    if rows == [], do: [blank_kv_row()], else: rows
  end

  defp secret_map_to_rows(_), do: [blank_kv_row()]

  defp decrypt_secret_for_form(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      _ -> ""
    end
  end

  defp decrypt_secret_for_form(_), do: ""

  defp blank_kv_row, do: %{"key" => "", "value" => ""}
  defp blank_arg_row, do: %{"key" => "", "value" => ""}

  defp add_mcp_row(rows_map, collection) when is_map(rows_map) do
    key = collection_to_key(collection)
    existing = Map.get(rows_map, key, [blank_kv_row()])
    blank = if key == :args, do: blank_arg_row(), else: blank_kv_row()
    Map.put(rows_map, key, existing ++ [blank])
  end

  defp remove_mcp_row(rows_map, collection, index) when is_map(rows_map) do
    key = collection_to_key(collection)
    existing = Map.get(rows_map, key, [blank_kv_row()])

    next =
      existing
      |> Enum.with_index()
      |> Enum.reject(fn {_row, idx} -> idx == index end)
      |> Enum.map(&elem(&1, 0))

    fallback = if key == :args, do: [blank_arg_row()], else: [blank_kv_row()]
    Map.put(rows_map, key, if(next == [], do: fallback, else: next))
  end

  defp collection_to_key("args"), do: :args
  defp collection_to_key("headers"), do: :headers
  defp collection_to_key("secret_headers"), do: :secret_headers
  defp collection_to_key("environments"), do: :environments
  defp collection_to_key("secret_environments"), do: :secret_environments
  defp collection_to_key(_), do: :headers

  defp apply_mcp_type_scope(attrs, "local") do
    attrs
    |> Map.put("url", nil)
    |> Map.put("headers", %{})
    |> Map.put("secret_headers", %{})
  end

  defp apply_mcp_type_scope(attrs, "remote") do
    attrs
    |> Map.put("command", nil)
    |> Map.put("args", [])
    |> Map.put("environments", %{})
    |> Map.put("secret_environments", %{})
  end

  defp apply_mcp_type_scope(attrs, _), do: attrs

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp mcp_module do
    Application.get_env(:zaq, :mcp_test_module, MCP)
  end

  defp mcp_test_failure_message(reason) do
    cond do
      mcp_capabilities_not_ready?(reason) ->
        "MCP tools test failed: server handshake not ready yet (capabilities not set). Please retry in a moment."

      mcp_endpoint_already_registered?(reason) ->
        "MCP tools test failed: stale test endpoint state detected and was reset. Please retry."

      mcp_unauthorized_error?(reason) ->
        "MCP tools test failed: unauthorized (401). Please check MCP authentication headers/credentials."

      mcp_runtime_call_exit?(reason) ->
        "MCP tools test failed: MCP client disconnected during request. Please retry."

      true ->
        "MCP tools test failed: #{inspect(reason)}"
    end
  end

  defp mcp_capabilities_not_ready?(reason) do
    reason
    |> inspect()
    |> String.contains?("Server capabilities not set")
  end

  defp mcp_endpoint_already_registered?(reason) do
    reason
    |> inspect()
    |> String.contains?("endpoint_already_registered")
  end

  defp mcp_unauthorized_error?(reason) do
    rendered = inspect(reason)

    String.contains?(rendered, "http_error, 401") or
      String.contains?(rendered, "unauthorized") or
      String.contains?(rendered, "AuthenticateToken authentication failed")
  end

  defp mcp_runtime_call_exit?(reason) do
    reason
    |> inspect()
    |> String.contains?("mcp_runtime_call_exit")
  end

  defp maybe_put_mcp_runtime_warnings(socket, payload) when is_map(payload) do
    warnings = mcp_runtime_warnings(payload)

    if warnings == [] do
      socket
    else
      put_flash(socket, :warning, "MCP runtime warnings: #{inspect(warnings)}")
    end
  end

  defp maybe_put_mcp_runtime_warnings(socket, _), do: socket

  defp mcp_runtime_warnings(payload) when is_map(payload) do
    payload
    |> mcp_map_get(:runtime, %{})
    |> mcp_map_get(:warnings, [])
  end

  defp mcp_map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp mcp_map_get(_map, _key, default), do: default

  defp load_llm_form(socket) do
    cfg = engine_get_llm_config()
    provider_id = provider_from_credential_id(cfg.credential_id)
    changeset = LLMConfig.changeset(cfg, %{})

    socket
    |> assign(:llm_credential_options, credential_options())
    |> assign(:llm_model_options, llm_model_options(provider_id))
    |> assign(:llm_capabilities, llm_model_capabilities(provider_id, cfg.model))
    |> assign(:llm_form, to_form(changeset, as: :llm_config))
  end

  defp load_embedding_form(socket) do
    cfg = engine_get_embedding_config()
    provider_id = provider_from_credential_id(cfg.credential_id)
    changeset = EmbeddingConfig.changeset(cfg, %{})

    socket
    |> assign(:embedding_credential_options, credential_options())
    |> assign(:embedding_model_options, embedding_model_options(provider_id))
    |> assign(:embedding_form, to_form(changeset, as: :embedding_config))
    |> assign(:embedding_locked, true)
    |> assign(:embedding_ready, engine_embedding_ready?())
    |> assign(:saved_model, cfg.model)
    |> assign(:saved_dimension, cfg.dimension)
    |> assign(:model_changed, false)
  end

  defp load_image_to_text_form(socket) do
    cfg = engine_get_image_to_text_config()
    provider_id = provider_from_credential_id(cfg.credential_id)
    changeset = ImageToTextConfig.changeset(cfg, %{})

    socket
    |> assign(:image_to_text_credential_options, credential_options())
    |> assign(:image_to_text_model_options, image_to_text_model_options(provider_id))
    |> assign(:image_to_text_form, to_form(changeset, as: :image_to_text_config))
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

  # ── Shared LLMDB helpers ───────────────────────────────────────────────

  # Returns the base_url for any provider, or "" for "custom".
  defp provider_endpoint("custom"), do: ""

  defp provider_endpoint(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.provider(provider_atom) do
      {:ok, provider} -> provider.base_url || ""
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end

  # Returns the execution path for the selected model of a provider, or "/chat/completions".
  defp provider_path("custom", _model_id), do: "/chat/completions"

  defp provider_path(provider_id, model_id) do
    provider_atom = String.to_existing_atom(provider_id)

    model = LLMDB.models(provider_atom) |> Enum.find(&(&1.id == model_id))

    path =
      model
      |> then(fn m -> m && m.execution && m.execution[:text] && m.execution[:text][:path] end)

    if is_binary(path), do: path, else: "/chat/completions"
  rescue
    ArgumentError -> "/chat/completions"
  end

  # Returns [{display_name, provider_id_string}] for providers whose models satisfy
  # model_filter, plus a "Custom" fallback. Pass `fn _ -> true end` for no filter.
  defp provider_options(model_filter) do
    llmdb_options =
      LLMDB.providers()
      |> Enum.reject(& &1.alias_of)
      |> Enum.filter(fn p ->
        LLMDB.models(p.id)
        |> Enum.any?(fn m -> not m.deprecated and not m.retired and model_filter.(m) end)
      end)
      |> Enum.map(&{&1.name || Atom.to_string(&1.id), Atom.to_string(&1.id)})
      |> Enum.sort_by(&elem(&1, 0))

    llmdb_options ++ [{"Custom", "custom"}]
  end

  # Returns [{model_name, model_id}] filtered by model_filter, or [] for "custom".
  defp model_options("custom", _model_filter), do: []

  defp model_options(provider_id, model_filter) do
    provider_atom = String.to_existing_atom(provider_id)

    LLMDB.models(provider_atom)
    |> Enum.reject(&(&1.deprecated or &1.retired))
    |> Enum.filter(model_filter)
    |> Enum.map(&{&1.name || &1.id, &1.id})
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  # ── Credential helpers ──────────────────────────────────────────────────

  defp credential_options do
    engine_list_ai_provider_credentials()
    |> Enum.map(&{&1.name, Integer.to_string(&1.id)})
  end

  defp provider_from_credential_id(credential_id) when credential_id in [nil, ""], do: "custom"

  defp provider_from_credential_id(credential_id) when is_binary(credential_id) do
    case Integer.parse(credential_id) do
      {id, ""} -> provider_from_credential_id(id)
      _ -> "custom"
    end
  end

  defp provider_from_credential_id(credential_id) when is_integer(credential_id) do
    case engine_get_ai_provider_credential(credential_id) do
      %{provider: provider} when is_binary(provider) -> provider
      _ -> "custom"
    end
  end

  defp provider_from_credential_id(_), do: "custom"

  defp ai_credential_for_action(:edit, id), do: engine_get_ai_provider_credential!(id)
  defp ai_credential_for_action(_, _), do: %Zaq.System.AIProviderCredential{}

  # ── LLM-specific helpers ───────────────────────────────────────────────

  defp llm_model_options(provider_id), do: model_options(provider_id, &tool_calling_model?/1)

  defp tool_calling_model?(m) do
    caps = m.capabilities || %{}

    case Map.get(caps, :tools) do
      %{enabled: true} -> true
      _ -> false
    end
  end

  defp llm_provider_path(provider_id, model_id), do: provider_path(provider_id, model_id)

  defp clamp_weight(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f |> max(0.0) |> min(1.0) |> Float.round(2)
      :error -> 0.5
    end
  end

  defp clamp_weight(val) when is_float(val), do: val |> max(0.0) |> min(1.0) |> Float.round(2)
  defp clamp_weight(_), do: 0.5

  # ── Embedding-specific helpers ─────────────────────────────────────────

  defp embedding_model_options(provider_id), do: model_options(provider_id, &embedding_model?/1)
  defp embedding_provider_endpoint(provider_id), do: provider_endpoint(provider_id)

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

  defp adjust_embedding_params(params, provider_id, previous_provider, previous_model) do
    model_id = params["model"]

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
  end

  defp embedding_model_changed?(params, saved_model, saved_dimension) do
    (not is_nil(params["model"]) && params["model"] != saved_model) ||
      (params["dimension"] not in [nil, ""] &&
         params["dimension"] != to_string(saved_dimension))
  end

  # ── Image-to-Text-specific helpers ────────────────────────────────────

  defp image_to_text_model_options(provider_id),
    do: model_options(provider_id, &image_input_model?/1)

  defp image_input_model?(m) do
    input = (m.modalities && m.modalities.input) || []
    :image in input
  end

  defp dispatch_engine(action, request \\ %{}) do
    Event.new(request, :engine, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp dispatch_agent(action, request \\ %{}) do
    Event.new(request, :agent, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp unwrap_ok!({:ok, value}), do: value
  defp unwrap_ok!(value), do: value

  defp engine_get_global_default_agent_id,
    do: dispatch_engine(:system_config_get_global_default_agent_id)

  defp engine_set_global_default_agent_id(id),
    do: dispatch_engine(:system_config_set_global_default_agent_id, %{id: id})

  defp engine_get_telemetry_config, do: dispatch_engine(:system_config_get_telemetry_config)

  defp engine_save_telemetry_config(changeset),
    do: dispatch_engine(:system_config_save_telemetry_config, %{changeset: changeset})

  defp engine_get_llm_config, do: dispatch_engine(:system_config_get_llm_config)

  defp engine_save_llm_config(changeset),
    do: dispatch_engine(:system_config_save_llm_config, %{changeset: changeset})

  defp engine_get_embedding_config, do: dispatch_engine(:system_config_get_embedding_config)

  defp engine_save_embedding_config(changeset),
    do: dispatch_engine(:system_config_save_embedding_config, %{changeset: changeset})

  defp engine_embedding_ready?, do: dispatch_engine(:system_config_embedding_ready)

  defp engine_get_image_to_text_config,
    do: dispatch_engine(:system_config_get_image_to_text_config)

  defp engine_save_image_to_text_config(changeset),
    do: dispatch_engine(:system_config_save_image_to_text_config, %{changeset: changeset})

  defp engine_list_ai_provider_credentials,
    do: dispatch_engine(:system_config_list_ai_provider_credentials)

  defp engine_get_ai_provider_credential(id),
    do: dispatch_engine(:system_config_get_ai_provider_credential, %{id: id})

  defp engine_get_ai_provider_credential!(id) do
    case dispatch_engine(:system_config_get_ai_provider_credential_bang, %{id: id}) do
      {:ok, credential} -> credential
      _ -> raise Ecto.NoResultsError, queryable: Zaq.System.AIProviderCredential
    end
  end

  defp engine_change_ai_provider_credential(credential, attrs),
    do:
      dispatch_engine(:system_config_change_ai_provider_credential, %{
        credential: credential,
        attrs: attrs
      })

  defp engine_create_ai_provider_credential(attrs),
    do: dispatch_engine(:system_config_create_ai_provider_credential, %{attrs: attrs})

  defp engine_update_ai_provider_credential(credential, attrs),
    do:
      dispatch_engine(:system_config_update_ai_provider_credential, %{
        credential: credential,
        attrs: attrs
      })

  defp engine_delete_ai_provider_credential(credential),
    do: dispatch_engine(:system_config_delete_ai_provider_credential, %{credential: credential})

  defp engine_connect_list_credentials,
    do: dispatch_engine(:system_config_connect_list_credentials)

  defp engine_connect_fetch_credential(id),
    do: dispatch_engine(:connect_fetch_credential, %{credential_id: id})

  defp engine_connect_change_credential(credential, attrs),
    do:
      dispatch_engine(:system_config_connect_change_credential, %{
        credential: credential,
        attrs: attrs
      })

  defp engine_connect_update_credential(credential, attrs),
    do:
      dispatch_engine(:system_config_connect_update_credential, %{
        credential: credential,
        attrs: attrs
      })

  defp engine_connect_list_grants(credential_id),
    do: dispatch_engine(:system_config_connect_list_grants, %{credential_id: credential_id})

  defp engine_connect_next_refresh_jobs_for_grants(grants),
    do: dispatch_engine(:system_config_connect_next_refresh_jobs_for_grants, %{grants: grants})

  defp engine_connect_delete_grant(grant),
    do: dispatch_engine(:system_config_connect_delete_grant, %{grant: grant})

  defp engine_connect_schedule_refresh(grant),
    do: dispatch_engine(:system_config_connect_schedule_refresh, %{grant: grant})

  defp agent_get_mcp_endpoint!(id) do
    dispatch_agent(:system_config_mcp_get_endpoint, %{id: id})
    |> unwrap_ok!()
  end

  defp agent_change_mcp_endpoint(endpoint, attrs \\ %{}),
    do: dispatch_agent(:system_config_mcp_change_endpoint, %{endpoint: endpoint, attrs: attrs})

  defp agent_filter_mcp_endpoints(filters, opts),
    do:
      dispatch_agent(:system_config_mcp_filter_endpoints, %{
        filters: filters,
        page: opts[:page],
        per_page: opts[:per_page]
      })

  defp agent_mcp_predefined_catalog,
    do: dispatch_agent(:system_config_mcp_predefined_catalog)

  defp agent_list_active_agents,
    do: dispatch_agent(:system_config_agent_list_active_agents)

  defp global_agent_options do
    agent_list_active_agents()
    |> Enum.map(fn agent -> {agent.name, agent.id} end)
  end

  defp sanitize_connect_credential_params(params) when is_map(params) do
    Map.drop(params, ["provider", "request_format"])
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    ZaqWeb.ChangesetErrors.format(changeset,
      join: false,
      humanize_fields: true,
      field_separator: " "
    )
  end

  defp reload_selected_connect_grants(socket, nil) do
    socket
    |> assign(:selected_connect_grants, [])
    |> assign(:selected_connect_refresh_schedule, %{})
  end

  defp reload_selected_connect_grants(socket, credential) do
    grants = engine_connect_list_grants(credential.id)
    refresh_schedule = engine_connect_next_refresh_jobs_for_grants(grants)

    socket
    |> assign(:selected_connect_grants, grants)
    |> assign(:selected_connect_refresh_schedule, refresh_schedule)
  end
end
