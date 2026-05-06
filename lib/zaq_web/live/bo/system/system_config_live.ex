defmodule ZaqWeb.Live.BO.System.SystemConfigLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.SearchableSelect

  alias Phoenix.LiveView.JS
  alias Zaq.Agent
  alias Zaq.Agent.MCP
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.System
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.TelemetryConfig
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils
  alias ZaqWeb.Components.BOModal

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
     |> assign(:global_default_agent_id, System.get_global_default_agent_id())
     |> load_ai_credential_form()
     |> load_ai_credentials()
     |> load_mcp_endpoint_form()
     |> load_mcp_endpoints()
     |> load_telemetry_form()
     |> load_llm_form()
     |> load_embedding_form()
     |> load_image_to_text_form()}
  end

  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ~w(telemetry llm embedding image_to_text ai_credentials mcp global) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :active_tab, :telemetry)}
  end

  # ── Tab navigation ─────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/bo/system-config?tab=#{tab}")}
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

  def handle_event("save_global_default_agent", %{"global_default_agent_id" => raw_id}, socket) do
    case System.set_global_default_agent_id(ParseUtils.parse_optional_int(raw_id)) do
      :ok ->
        {:noreply,
         socket
         |> assign(:global_default_agent_id, System.get_global_default_agent_id())
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
      System.get_embedding_config()
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
    credential = System.get_ai_provider_credential!(id)

    {:noreply,
     socket
     |> assign(:ai_credential_action, :edit)
     |> assign(:ai_credential_id, credential.id)
     |> assign(:ai_credential_modal, true)
     |> assign(
       :ai_credential_form,
       credential
       |> System.change_ai_provider_credential(%{})
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
      |> System.get_ai_provider_credential!()
      |> System.delete_ai_provider_credential()

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
      |> System.change_ai_provider_credential(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :ai_credential_form, to_form(changeset, as: :ai_credential))}
  end

  def handle_event("save_ai_credential", %{"ai_credential" => params}, socket) do
    result =
      case socket.assigns.ai_credential_action do
        :edit ->
          socket.assigns.ai_credential_id
          |> System.get_ai_provider_credential!()
          |> System.update_ai_provider_credential(params)

        _ ->
          System.create_ai_provider_credential(params)
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
    endpoint = MCP.get_mcp_endpoint!(id)

    {:noreply,
     socket
     |> assign(:mcp_endpoint_action, :edit)
     |> assign(:mcp_endpoint_id, endpoint.id)
     |> assign(:mcp_endpoint_delete_confirm_modal, false)
     |> assign(:mcp_endpoint_modal, true)
     |> assign(:mcp_endpoint_form, to_form(MCP.change_mcp_endpoint(endpoint), as: :mcp_endpoint))
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

        predefined = endpoint.predefined_id && MCP.predefined_catalog()[endpoint.predefined_id]

        socket =
          if is_map(predefined) and predefined[:editable] do
            socket
            |> assign(:mcp_endpoint_action, :edit)
            |> assign(:mcp_endpoint_id, endpoint.id)
            |> assign(:mcp_endpoint_modal, true)
            |> assign(:mcp_endpoint_delete_confirm_modal, false)
            |> assign(
              :mcp_endpoint_form,
              to_form(MCP.change_mcp_endpoint(endpoint), as: :mcp_endpoint)
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
      |> MCP.change_mcp_endpoint(parsed)
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
    changeset = EmbeddingConfig.changeset(System.get_embedding_config(), params)

    case System.save_embedding_config(changeset) do
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
    changeset = TelemetryConfig.changeset(System.get_telemetry_config(), %{})
    assign(socket, :telemetry_form, to_form(changeset, as: :telemetry_config))
  end

  defp load_ai_credentials(socket) do
    assign(socket, :ai_credentials, System.list_ai_provider_credentials())
  end

  defp load_ai_credential_form(socket) do
    changeset = System.change_ai_provider_credential(%Zaq.System.AIProviderCredential{}, %{})
    assign(socket, :ai_credential_form, to_form(changeset, as: :ai_credential))
  end

  defp load_mcp_endpoints(socket) do
    filters = %{
      "name" => socket.assigns.mcp_filter_name,
      "type" => socket.assigns.mcp_filter_type,
      "status" => socket.assigns.mcp_filter_status
    }

    {entries, total} =
      MCP.filter_mcp_endpoints(filters,
        page: socket.assigns.mcp_page,
        per_page: socket.assigns.mcp_per_page
      )

    socket
    |> assign(:mcp_endpoints, entries)
    |> assign(:mcp_total_count, total)
  end

  defp load_mcp_endpoint_form(socket) do
    changeset =
      MCP.change_mcp_endpoint(%MCP.Endpoint{}, %{
        "type" => "local",
        "status" => "disabled",
        "timeout_ms" => 5000
      })

    socket
    |> assign(:mcp_endpoint_form, to_form(changeset, as: :mcp_endpoint))
    |> assign(:mcp_endpoint_rows, mcp_rows(%MCP.Endpoint{}))
  end

  defp mcp_endpoint_for_action(:edit, id), do: MCP.get_mcp_endpoint!(id)
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
    cfg = System.get_llm_config()
    provider_id = provider_from_credential_id(cfg.credential_id)
    changeset = LLMConfig.changeset(cfg, %{})

    socket
    |> assign(:llm_credential_options, credential_options())
    |> assign(:llm_model_options, llm_model_options(provider_id))
    |> assign(:llm_capabilities, llm_model_capabilities(provider_id, cfg.model))
    |> assign(:llm_form, to_form(changeset, as: :llm_config))
  end

  defp load_embedding_form(socket) do
    cfg = System.get_embedding_config()
    provider_id = provider_from_credential_id(cfg.credential_id)
    changeset = EmbeddingConfig.changeset(cfg, %{})

    socket
    |> assign(:embedding_credential_options, credential_options())
    |> assign(:embedding_model_options, embedding_model_options(provider_id))
    |> assign(:embedding_form, to_form(changeset, as: :embedding_config))
    |> assign(:embedding_locked, true)
    |> assign(:embedding_ready, System.embedding_ready?())
    |> assign(:saved_model, cfg.model)
    |> assign(:saved_dimension, cfg.dimension)
    |> assign(:model_changed, false)
  end

  defp load_image_to_text_form(socket) do
    cfg = System.get_image_to_text_config()
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
    System.list_ai_provider_credentials()
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
    case System.get_ai_provider_credential(credential_id) do
      %{provider: provider} when is_binary(provider) -> provider
      _ -> "custom"
    end
  end

  defp provider_from_credential_id(_), do: "custom"

  defp ai_credential_for_action(:edit, id), do: System.get_ai_provider_credential!(id)
  defp ai_credential_for_action(_, _), do: %Zaq.System.AIProviderCredential{}

  # ── LLM-specific helpers ───────────────────────────────────────────────

  defp llm_model_options(provider_id), do: model_options(provider_id, fn _ -> true end)
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

  # ── Telemetry Panel ────────────────────────────────────────────────────

  attr :form, :any, required: true

  defp telemetry_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Telemetry Collection</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Control infra event capture and minimum duration thresholds.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="telemetry-config-form"
          for={@form}
          phx-submit="save_telemetry"
          phx-change="validate_telemetry"
          class="space-y-5"
        >
          <div class="flex items-center justify-between py-2 border-b border-black/[0.05]">
            <div>
              <p class="font-mono text-[0.82rem] font-semibold text-black">
                Capture infra metrics
              </p>
              <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                Collect Phoenix request, Repo query, and Oban runtime metrics.
              </p>
            </div>
            <label class="relative inline-flex items-center cursor-pointer">
              <input type="hidden" name="telemetry_config[capture_infra_metrics]" value="false" />
              <input
                type="checkbox"
                name="telemetry_config[capture_infra_metrics]"
                value="true"
                checked={@form[:capture_infra_metrics].value in [true, "true"]}
                class="sr-only peer"
              />
              <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
              </div>
            </label>
          </div>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Request Duration Threshold (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[request_duration_threshold_ms]"
                value={@form[:request_duration_threshold_ms].value}
                phx-debounce="400"
                placeholder="0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:request_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Repo Query Threshold (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[repo_query_duration_threshold_ms]"
                value={@form[:repo_query_duration_threshold_ms].value}
                phx-debounce="400"
                placeholder="0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:repo_query_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                No-Answer Alert Threshold (%)
              </label>
              <input
                type="number"
                min="0"
                max="100"
                name="telemetry_config[no_answer_alert_threshold_percent]"
                value={@form[:no_answer_alert_threshold_percent].value}
                phx-debounce="400"
                placeholder="10"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:no_answer_alert_threshold_percent].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Conversations Response SLA (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[conversation_response_sla_ms]"
                value={@form[:conversation_response_sla_ms].value}
                phx-debounce="400"
                placeholder="1500"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:conversation_response_sla_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="bg-[#fafafa] rounded-xl border border-black/5 px-4 py-3">
            <p class="font-mono text-[0.72rem] text-black/50 leading-relaxed">
              Thresholds are applied by the telemetry collector and Conversations dashboard alerts.
              Use <span class="font-semibold text-black/70">0</span> to capture every event.
            </p>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Telemetry Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :global_agent_options, :list, required: true
  attr :global_default_agent_id, :any, required: true

  defp global_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Global Configuration</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Configure system-wide defaults used when channel-level routing does not select a configured agent.
        </p>
      </div>
      <div class="px-8 py-6">
        <label class="font-mono text-[0.68rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
          Global Default Agent
        </label>
        <form phx-submit="save_global_default_agent" class="flex items-center gap-2">
          <select
            id="global-default-agent-select"
            name="global_default_agent_id"
            class="w-full max-w-md font-mono text-[0.82rem] text-black border border-black/10 rounded-xl h-10 px-3 bg-white focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4]"
          >
            <option value="" selected={is_nil(@global_default_agent_id)}>
              Default Zaq Agent
            </option>
            <option
              :for={{name, id} <- @global_agent_options}
              value={id}
              selected={to_string(@global_default_agent_id || "") == to_string(id)}
            >
              {name}
            </option>
          </select>
          <button
            type="submit"
            class="font-mono text-[0.72rem] px-3 py-2 rounded-lg border border-black/10 text-black/60 hover:text-black hover:border-black/20"
          >
            Save
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp global_agent_options do
    Agent.list_active_agents()
    |> Enum.map(fn agent -> {agent.name, agent.id} end)
  end

  # ── LLM Panel ─────────────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :capabilities, :map, required: true

  defp llm_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">LLM</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          OpenAI-compatible language model endpoint used for chat and retrieval.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="llm-config-form"
          for={@form}
          phx-submit="save_llm"
          phx-change="validate_llm"
          class="space-y-5"
        >
          <input type="hidden" name="llm_config[path]" value={@form[:path].value} />
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                AI Credential
              </label>
              <.searchable_select
                id="llm-credential-select"
                name="llm_config[credential_id]"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                placeholder="Search credentials..."
                empty_label="Select a credential..."
              />
              <p
                :for={{msg, opts} <- @form[:credential_id].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Model
              </label>
              <.searchable_select
                :if={@model_options != []}
                id="llm-model-select"
                name="llm_config[model]"
                value={@form[:model].value}
                options={@model_options}
                placeholder="Search models..."
                empty_label="Select a model..."
              />
              <input
                :if={@model_options == []}
                type="text"
                name="llm_config[model]"
                value={@form[:model].value}
                required
                phx-debounce="400"
                placeholder="llama-3.3-70b-instruct"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Temperature
              </label>
              <input
                type="number"
                min="0"
                max="2"
                step="0.1"
                name="llm_config[temperature]"
                value={@form[:temperature].value}
                phx-debounce="400"
                placeholder="0.0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:temperature].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Top-P
              </label>
              <input
                type="number"
                min="0.01"
                max="1"
                step="0.05"
                name="llm_config[top_p]"
                value={@form[:top_p].value}
                phx-debounce="400"
                placeholder="0.9"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:top_p].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="font-mono text-[0.82rem] font-semibold text-black">JSON Mode</p>
                  <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                    Force structured JSON output.
                  </p>
                </div>
                <label class="relative inline-flex items-center cursor-pointer shrink-0 ml-3">
                  <input type="hidden" name="llm_config[supports_json_mode]" value="false" />
                  <input
                    type="checkbox"
                    name="llm_config[supports_json_mode]"
                    value="true"
                    checked={@form[:supports_json_mode].value in [true, "true"]}
                    class="sr-only peer"
                  />
                  <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
                  </div>
                </label>
              </div>
              <p
                :if={
                  @capabilities.json_mode == false &&
                    @form[:supports_json_mode].value in [true, "true"]
                }
                class="font-mono text-[0.72rem] text-amber-600 mt-1"
              >
                Model doesn't support JSON mode — recommend turning off.
              </p>
            </div>
            <div>
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="font-mono text-[0.82rem] font-semibold text-black">Logprobs</p>
                  <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                    Log-probability confidence scores.
                  </p>
                </div>
                <label class="relative inline-flex items-center cursor-pointer shrink-0 ml-3">
                  <input type="hidden" name="llm_config[supports_logprobs]" value="false" />
                  <input
                    type="checkbox"
                    name="llm_config[supports_logprobs]"
                    value="true"
                    checked={@form[:supports_logprobs].value in [true, "true"]}
                    class="sr-only peer"
                  />
                  <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
                  </div>
                </label>
              </div>
              <p
                :if={
                  @capabilities.logprobs == false && @form[:supports_logprobs].value in [true, "true"]
                }
                class="font-mono text-[0.72rem] text-amber-600 mt-1"
              >
                Model doesn't support logprobs — recommend turning off.
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Max Context Window (tokens)
              </label>
              <input
                type="number"
                min="1"
                name="llm_config[max_context_window]"
                value={@form[:max_context_window].value}
                phx-debounce="400"
                placeholder="5000"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:max_context_window].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Distance Threshold
              </label>
              <input
                type="number"
                min="0.01"
                step="0.01"
                name="llm_config[distance_threshold]"
                value={@form[:distance_threshold].value}
                phx-debounce="400"
                placeholder="1.2"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:distance_threshold].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <details
            id="llm-fusion-advanced"
            phx-hook="DetailsKeepOpen"
            class="border border-black/[0.08] rounded-xl overflow-hidden"
          >
            <summary class="cursor-pointer select-none px-4 py-3 font-mono text-[0.75rem] font-semibold text-black/50 uppercase tracking-wider hover:bg-black/[0.02] transition-colors list-none flex items-center gap-2">
              <svg
                class="w-3.5 h-3.5 transition-transform details-open:rotate-90"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
                  clip-rule="evenodd"
                />
              </svg>
              Advanced — Hybrid Search Fusion Weights
            </summary>
            <div class="px-4 pb-4 pt-3 bg-black/[0.01] border-t border-black/[0.06] grid grid-cols-2 gap-4">
              <div>
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                  BM25 Weight
                </label>
                <input
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  name="llm_config[fusion_bm25_weight]"
                  value={@form[:fusion_bm25_weight].value}
                  phx-debounce="400"
                  placeholder="0.5"
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
                <p
                  :for={{msg, opts} <- @form[:fusion_bm25_weight].errors}
                  class="font-mono text-[0.72rem] text-red-500 mt-1.5"
                >
                  {translate_error({msg, opts})}
                </p>
              </div>
              <div>
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                  Vector Weight
                </label>
                <input
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  name="llm_config[fusion_vector_weight]"
                  value={@form[:fusion_vector_weight].value}
                  phx-debounce="400"
                  placeholder="0.5"
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
                <p
                  :for={{msg, opts} <- @form[:fusion_vector_weight].errors}
                  class="font-mono text-[0.72rem] text-red-500 mt-1.5"
                >
                  {translate_error({msg, opts})}
                </p>
              </div>
            </div>
          </details>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save LLM Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Embedding Panel ───────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :locked, :boolean, default: false
  attr :unlock_modal, :boolean, default: false
  attr :model_changed, :boolean, default: false
  attr :save_confirm_modal, :boolean, default: false

  defp embedding_panel(assigns) do
    ~H"""
    <%!-- Unlock model — informational note --%>
    <div
      :if={@unlock_modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.08] w-full max-w-md mx-4 p-6">
        <h3 class="font-mono text-[0.95rem] font-bold text-black mb-2">Unlock Model Selection</h3>
        <p class="font-mono text-[0.8rem] text-black/60 leading-relaxed mb-5">
          You are about to unlock model selection. If you pick a different model, saving will permanently delete all existing embeddings and require full re-ingestion.
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_unlock_embedding"
            class="font-mono text-[0.82rem] px-5 py-2.5 rounded-xl border border-black/10 text-black/60 hover:bg-black/[0.04] transition-all"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_unlock_embedding"
            class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
          >
            Unlock
          </button>
        </div>
      </div>
    </div>

    <%!-- Destructive save confirmation modal --%>
    <div
      :if={@save_confirm_modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.08] w-full max-w-md mx-4 p-6">
        <h3 class="font-mono text-[0.95rem] font-bold text-black mb-2">Delete All Embeddings?</h3>
        <p class="font-mono text-[0.8rem] text-black/60 leading-relaxed mb-5">
          All existing embeddings will be permanently deleted and full re-ingestion will be required. This cannot be undone.
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_save_embedding"
            class="font-mono text-[0.82rem] px-5 py-2.5 rounded-xl border border-black/10 text-black/60 hover:bg-black/[0.04] transition-all"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_save_embedding"
            class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-red-500 text-white hover:bg-red-600 transition-all"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>

    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Embedding</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          OpenAI-compatible embedding endpoint used for vector search.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="embedding-config-form"
          for={@form}
          phx-submit="save_embedding"
          phx-change="validate_embedding"
          class="space-y-5"
        >
          <div class="grid grid-cols-2 gap-4 items-start">
            <div>
              <div class="h-7 flex items-center mb-2">
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
                  AI Credential
                </label>
              </div>
              <.searchable_select
                id="embedding-credential-select"
                name="embedding_config[credential_id]"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                placeholder="Search credentials..."
                empty_label="Select a credential..."
              />
              <p
                :for={{msg, opts} <- @form[:credential_id].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <div class="h-7 flex items-center justify-between mb-2">
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
                  Model
                </label>
                <div :if={@locked} class="flex items-center gap-2">
                  <span class="flex items-center gap-1 font-mono text-[0.68rem] font-semibold text-emerald-600 bg-emerald-50 border border-emerald-200 px-2 py-1 rounded-md">
                    <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                      />
                    </svg>
                    Locked
                  </span>
                  <button
                    type="button"
                    phx-click="unlock_embedding"
                    class="font-mono text-[0.68rem] font-semibold px-2 py-1 rounded-md border border-amber-300 text-amber-600 bg-amber-50 hover:bg-amber-100 transition-all"
                  >
                    Unlock
                  </button>
                </div>
              </div>
              <div class={[@locked && "opacity-50 pointer-events-none"]}>
                <.searchable_select
                  :if={@model_options != []}
                  id="embedding-model-select"
                  name="embedding_config[model]"
                  value={@form[:model].value}
                  options={@model_options}
                  placeholder="Search models..."
                  empty_label="Select a model..."
                />
                <input
                  :if={@model_options == []}
                  type="text"
                  name="embedding_config[model]"
                  value={@form[:model].value}
                  phx-debounce="400"
                  placeholder="bge-multilingual-gemma2"
                  disabled={@locked}
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
              </div>
              <p
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Dimension
            </label>
            <input
              type="number"
              min="1"
              name="embedding_config[dimension]"
              value={@form[:dimension].value}
              phx-debounce="400"
              placeholder="3584"
              disabled={@locked}
              class={[
                "w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 placeholder:text-black/25 transition-all",
                if(@locked,
                  do: "bg-black/[0.03] text-black/40 cursor-not-allowed",
                  else:
                    "bg-[#fafafa] focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4]"
                )
              ]}
            />
            <p
              :for={{msg, opts} <- @form[:dimension].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
            <p
              :if={not @locked and @form[:dimension].value not in [nil, ""]}
              class="font-mono text-[0.72rem] text-amber-600 mt-1.5"
            >
              Changing the model or dimension will permanently delete all chunks and require re-ingestion.
            </p>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Min Tokens
              </label>
              <input
                type="number"
                min="1"
                name="embedding_config[chunk_min_tokens]"
                value={@form[:chunk_min_tokens].value}
                phx-debounce="400"
                placeholder="400"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:chunk_min_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Max Tokens
              </label>
              <input
                type="number"
                min="1"
                name="embedding_config[chunk_max_tokens]"
                value={@form[:chunk_max_tokens].value}
                phx-debounce="400"
                placeholder="900"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:chunk_max_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class={[
                "font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl text-white shadow-sm transition-all",
                if(@model_changed,
                  do: "bg-red-500 hover:bg-red-600 shadow-red-500/20",
                  else: "bg-[#03b6d4] hover:bg-[#029ab3] shadow-[#03b6d4]/20"
                )
              ]}
            >
              Save Embedding Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Image to Text Panel ───────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true

  defp image_to_text_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Image to Text</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Vision model endpoint used to extract text from images and PDFs during ingestion.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="image-to-text-config-form"
          for={@form}
          phx-submit="save_image_to_text"
          phx-change="validate_image_to_text"
          class="space-y-5"
        >
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                AI Credential
              </label>
              <.searchable_select
                id="image-to-text-credential-select"
                name="image_to_text_config[credential_id]"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                placeholder="Search credentials..."
                empty_label="Select a credential..."
              />
              <p
                :for={{msg, opts} <- @form[:credential_id].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Model
              </label>
              <.searchable_select
                :if={@model_options != []}
                id="image-to-text-model-select"
                name="image_to_text_config[model]"
                value={@form[:model].value}
                options={@model_options}
                placeholder="Search models..."
                empty_label="Select a model..."
              />
              <input
                :if={@model_options == []}
                type="text"
                name="image_to_text_config[model]"
                value={@form[:model].value}
                phx-debounce="400"
                placeholder="pixtral-12b-2409"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Image to Text Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── MCP Administration Panel ────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :total_count, :integer, required: true
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :filter_name, :string, required: true
  attr :filter_type, :string, required: true
  attr :filter_status, :string, required: true
  attr :form, :any, required: true
  attr :rows, :map, required: true
  attr :modal, :boolean, required: true
  attr :action, :atom, required: true
  attr :delete_confirm_modal, :boolean, required: true

  defp mcp_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
        <div>
          <h2 class="font-mono text-[0.95rem] font-bold text-black">MCP Administration</h2>
          <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
            Manage Model Context Protocol endpoints and test tool loading.
          </p>
        </div>
        <button
          type="button"
          phx-click="new_mcp_endpoint"
          class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
        >
          + Add MCP
        </button>
      </div>

      <form
        phx-change="filter_mcp_endpoints"
        class="px-8 py-4 border-b border-black/[0.06] grid grid-cols-3 gap-3"
      >
        <input
          type="text"
          name="mcp_filter_name"
          value={@filter_name}
          phx-debounce="300"
          placeholder="Search by name"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        />
        <select
          name="mcp_filter_type"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        >
          <option value="all" selected={@filter_type == "all"}>All types</option>
          <option value="local" selected={@filter_type == "local"}>Local</option>
          <option value="remote" selected={@filter_type == "remote"}>Remote</option>
        </select>
        <select
          name="mcp_filter_status"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        >
          <option value="all" selected={@filter_status == "all"}>All statuses</option>
          <option value="enabled" selected={@filter_status == "enabled"}>Enabled</option>
          <option value="disabled" selected={@filter_status == "disabled"}>Disabled</option>
        </select>
      </form>

      <div :if={@entries == []} class="px-8 py-10 text-center">
        <p class="font-mono text-[0.85rem] text-black/50">No MCP entries found.</p>
      </div>

      <div :if={@entries != []} class="divide-y divide-black/[0.06]">
        <div :for={entry <- @entries} class="px-8 py-4 flex items-center justify-between gap-4">
          <div class="min-w-0 flex items-start gap-3">
            <div class="mt-0.5 inline-flex h-7 w-7 shrink-0 items-center justify-center overflow-hidden rounded-lg">
              <ZaqWeb.Components.MCPEndpointIcons.icon
                endpoint_key={entry.predefined_id}
                class="h-7 w-7"
              />
            </div>
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <p class="font-mono text-[0.82rem] font-semibold text-black truncate">{entry.name}</p>
                <span class={[
                  "h-2 w-2 rounded-full",
                  if(entry.status == "enabled", do: "bg-emerald-500", else: "bg-red-500")
                ]} />
              </div>
              <p class="font-mono text-[0.7rem] text-black/45 mt-0.5">
                {entry.type}<span :if={entry.predefined?}> · predefined</span>
              </p>
              <p :if={entry.description} class="font-mono text-[0.7rem] text-black/35 mt-0.5 truncate">
                {entry.description}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={not entry.persisted? and entry.predefined?}
              type="button"
              phx-click="enable_predefined_mcp"
              phx-value-predefined_id={entry.predefined_id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Enable
              <span :if={entry.auto_enabled} class="ml-1" title="Immediately available">⚡</span>
            </button>
            <button
              :if={entry.persisted?}
              type="button"
              phx-click="edit_mcp_endpoint"
              phx-value-id={entry.id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Edit
            </button>
            <.loading_action_button
              :if={entry.persisted?}
              id={"mcp-test-button-#{entry.id}"}
              phx-click="test_mcp_endpoint"
              phx-value-id={entry.id}
              label="Test"
              loading_label="Testing..."
              class="mcp-test-button font-mono text-[0.72rem] px-3 py-1.5 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3]"
            />
          </div>
        </div>
      </div>

      <div
        :if={@total_count > 0}
        class="px-8 py-3 border-t border-black/[0.06] flex items-center justify-between"
      >
        <span class="font-mono text-[0.68rem] text-black/40">
          {@page * @per_page - @per_page + 1}–{min(@page * @per_page, @total_count)} of {@total_count}
        </span>
        <div class="flex gap-1">
          <button
            :if={@page > 1}
            type="button"
            phx-click="change_mcp_page"
            phx-value-page={@page - 1}
            class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5"
          >
            ← Prev
          </button>
          <button
            :if={@page * @per_page < @total_count}
            type="button"
            phx-click="change_mcp_page"
            phx-value-page={@page + 1}
            class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5"
          >
            Next →
          </button>
        </div>
      </div>
    </div>

    <BOModal.form_dialog
      :if={@modal}
      id="mcp-endpoint-modal"
      cancel_event="close_mcp_endpoint_modal"
      title={if @action == :edit, do: "Edit MCP Endpoint", else: "New MCP Endpoint"}
      max_width_class="max-w-3xl"
    >
      <.form
        id="mcp-endpoint-form"
        for={@form}
        phx-change="validate_mcp_endpoint"
        phx-submit="save_mcp_endpoint"
        class="space-y-4"
      >
        <p
          :for={{msg, opts} <- Keyword.get_values(@form.errors, :base)}
          class="whitespace-pre-line font-mono text-[0.72rem] text-red-500 bg-red-50 border border-red-100 rounded-xl px-3 py-2"
        >
          {translate_error({msg, opts})}
        </p>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_160px_160px]">
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Name
            </label>
            <input
              type="text"
              name="mcp_endpoint[name]"
              value={@form[:name].value}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Status
            </label>
            <label class="h-11 px-1 inline-flex items-center gap-3 cursor-pointer">
              <input
                type="hidden"
                name="mcp_endpoint[status]"
                value={if @form[:status].value == "enabled", do: "enabled", else: "disabled"}
              />
              <input
                type="checkbox"
                checked={@form[:status].value == "enabled"}
                class="sr-only peer"
                phx-click={
                  if @form[:status].value == "enabled" do
                    JS.set_attribute({"value", "disabled"},
                      to: "#mcp-endpoint-form input[name='mcp_endpoint[status]']"
                    )
                  else
                    JS.set_attribute({"value", "enabled"},
                      to: "#mcp-endpoint-form input[name='mcp_endpoint[status]']"
                    )
                  end
                  |> JS.dispatch("change", to: "#mcp-endpoint-form")
                }
              />
              <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm relative">
              </div>
              <span class="font-mono text-[0.78rem] text-black/70">
                {if @form[:status].value == "enabled", do: "Enabled", else: "Disabled"}
              </span>
            </label>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Timeout (ms)
            </label>
            <input
              type="number"
              min="1"
              name="mcp_endpoint[timeout_ms]"
              value={@form[:timeout_ms].value || 5000}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
        </div>

        <input
          type="hidden"
          name="mcp_endpoint[predefined_id]"
          value={@form[:predefined_id].value || ""}
        />

        <div class="grid grid-cols-1 gap-4 md:grid-cols-[160px_minmax(0,1fr)]">
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Type
            </label>
            <select
              name="mcp_endpoint[type]"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            >
              <option value="local" selected={@form[:type].value == "local"}>local</option>
              <option value="remote" selected={@form[:type].value == "remote"}>remote</option>
            </select>
          </div>

          <div :if={@form[:type].value == "local"}>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Command
            </label>
            <input
              type="text"
              name="mcp_endpoint[command]"
              value={@form[:command].value || ""}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>

          <div :if={@form[:type].value == "remote"}>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              URL
            </label>
            <input
              type="text"
              name="mcp_endpoint[url]"
              value={@form[:url].value || ""}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
        </div>

        <div :if={@form[:type].value == "local"} class="space-y-4">
          <.mcp_args_rows rows={@rows.args} collection="args" label="Args" placeholder="--flag" />

          <.mcp_kv_rows
            rows={@rows.environments}
            collection="environments"
            label="Environments"
            key_placeholder="KEY"
            value_placeholder="value"
          />

          <.mcp_secret_kv_rows
            rows={@rows.secret_environments}
            collection="secret_environments"
            label="Secret environments"
            key_placeholder="SECRET_KEY"
          />
        </div>

        <div :if={@form[:type].value == "remote"} class="space-y-4">
          <.mcp_kv_rows
            rows={@rows.headers}
            collection="headers"
            label="Headers"
            key_placeholder="Header-Name"
            value_placeholder="value"
          />

          <.mcp_secret_kv_rows
            rows={@rows.secret_headers}
            collection="secret_headers"
            label="Secret headers"
            key_placeholder="Authorization"
          />
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Settings (JSON)
          </label>
          <textarea
            name="mcp_endpoint[settings_text]"
            rows="4"
            class="w-full font-mono text-[0.84rem] text-black border border-black/10 rounded-xl px-4 py-3 bg-[#fafafa]"
          >{@rows.settings}</textarea>
        </div>
      </.form>

      <:actions>
        <button
          :if={@action == :edit}
          type="button"
          phx-click="open_delete_mcp_endpoint_confirm"
          class="inline-flex items-center gap-2 font-mono text-[0.8rem] px-4 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50"
        >
          <.icon name="hero-trash" class="h-4 w-4" /> Delete endpoint
        </button>
        <button
          type="submit"
          form="mcp-endpoint-form"
          class="font-mono text-[0.8rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3]"
        >
          Save endpoint
        </button>
      </:actions>

      <ZaqWeb.Components.BOModal.confirm_dialog
        :if={@delete_confirm_modal}
        id="mcp-endpoint-delete-confirm"
        cancel_event="cancel_delete_mcp_endpoint"
        confirm_event="confirm_delete_mcp_endpoint"
        title="Delete MCP Endpoint?"
        message="This action removes the endpoint. Associated runtime tools will be unsynced from active agents."
        confirm_label="Delete"
        cancel_label="Cancel"
      />
    </BOModal.form_dialog>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""

  defp mcp_args_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            placeholder={@placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :key_placeholder, :string, default: "KEY"
  attr :value_placeholder, :string, default: "value"

  defp mcp_kv_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][key]"}
            value={row["key"]}
            placeholder={@key_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            placeholder={@value_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :key_placeholder, :string, default: "KEY"

  defp mcp_secret_kv_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][key]"}
            value={row["key"]}
            placeholder={@key_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.secret_input
            id={"mcp-#{@collection}-#{idx}"}
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            input_class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 pr-10 bg-[#fafafa]"
            button_class="absolute right-3 top-1/2 -translate-y-1/2 text-black/30 hover:text-black/60"
            wrapper_class="relative"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :collection, :string, required: true
  attr :index, :integer, required: true

  defp mcp_row_delete_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_mcp_row"
      phx-value-collection={@collection}
      phx-value-index={@index}
      aria-label="Remove row"
      title="Remove row"
      class="inline-flex h-10 w-10 items-center justify-center rounded-lg border border-red-200 text-red-500 hover:bg-red-50 hover:text-red-600"
    >
      <.icon name="hero-trash" class="h-4 w-4" />
    </button>
    """
  end

  # ── AI Credentials Panel ───────────────────────────────────────────────

  attr :credentials, :list, required: true
  attr :form, :any, required: true
  attr :modal, :boolean, required: true
  attr :delete_confirm_modal, :boolean, default: false
  attr :action, :atom, required: true

  defp ai_credentials_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
        <div>
          <h2 class="font-mono text-[0.95rem] font-bold text-black">AI Credentials</h2>
          <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
            Reusable AI provider credentials used by LLM, Embedding, and Image to Text.
          </p>
        </div>
        <button
          type="button"
          phx-click="new_ai_credential"
          class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
        >
          + New credential
        </button>
      </div>

      <div :if={@credentials == []} class="px-8 py-10 text-center">
        <p class="font-mono text-[0.85rem] text-black/50">No AI credentials configured yet.</p>
      </div>

      <div :if={@credentials != []} class="divide-y divide-black/[0.06]">
        <button
          :for={credential <- @credentials}
          type="button"
          phx-click="edit_ai_credential"
          phx-value-id={credential.id}
          class="w-full text-left px-8 py-4 hover:bg-black/[0.02] transition-all"
        >
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="font-mono text-[0.82rem] font-semibold text-black">{credential.name}</p>
              <p class="font-mono text-[0.7rem] text-black/50 mt-0.5">
                {credential.provider}
              </p>
              <p :if={credential.description} class="font-mono text-[0.7rem] text-black/35 mt-0.5">
                {credential.description}
              </p>
            </div>
            <span class={[
              "font-mono text-[0.64rem] px-2 py-1 rounded border",
              if(credential.sovereign,
                do: "text-emerald-700 bg-emerald-50 border-emerald-200",
                else: "text-black/60 bg-black/[0.03] border-black/10"
              )
            ]}>
              {if credential.sovereign, do: "Sovereign", else: "Non-sovereign"}
            </span>
          </div>
        </button>
      </div>
    </div>

    <div
      :if={@modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.08] w-full max-w-2xl mx-4 p-6">
        <h3 class="font-mono text-[0.95rem] font-bold text-black mb-4">
          {if @action == :edit, do: "Edit AI Credential", else: "New AI Credential"}
        </h3>

        <.form
          id="ai-credential-form"
          for={@form}
          phx-change="validate_ai_credential"
          phx-submit="save_ai_credential"
          class="space-y-4"
        >
          <p
            :for={{msg, opts} <- Keyword.get_values(@form.errors, :base)}
            class="font-mono text-[0.72rem] text-red-500 bg-red-50 border border-red-100 rounded-xl px-3 py-2"
          >
            {translate_error({msg, opts})}
          </p>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Name
              </label>
              <input
                type="text"
                name="ai_credential[name]"
                value={@form[:name].value}
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
              />
              <p
                :for={{msg, opts} <- @form[:name].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Provider
              </label>
              <.searchable_select
                id="ai-credential-provider-select"
                name="ai_credential[provider]"
                value={@form[:provider].value}
                options={provider_options(fn _ -> true end)}
                placeholder="Search providers..."
                empty_label="Select a provider..."
              />
              <p
                :for={{msg, opts} <- @form[:provider].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>

          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Endpoint URL
            </label>
            <input
              type="text"
              name="ai_credential[endpoint]"
              value={@form[:endpoint].value}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
            <p
              :for={{msg, opts} <- @form[:endpoint].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
          </div>

          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              API Key
            </label>
            <div class="relative">
              <input
                type="text"
                id="ai-credential-api-key-input"
                name="ai_credential[api_key]"
                value={@form[:api_key].value}
                autocomplete="off"
                style="-webkit-text-security: disc;"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 pr-10 bg-[#fafafa]"
              />
              <button
                type="button"
                id="ai-credential-api-key-show"
                phx-click={
                  JS.remove_attribute("style", to: "#ai-credential-api-key-input")
                  |> JS.add_class("hidden", to: "#ai-credential-api-key-show")
                  |> JS.remove_class("hidden", to: "#ai-credential-api-key-hide")
                }
                class="absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"
                  /><path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                  />
                </svg>
              </button>
              <button
                type="button"
                id="ai-credential-api-key-hide"
                phx-click={
                  JS.set_attribute({"style", "-webkit-text-security: disc;"},
                    to: "#ai-credential-api-key-input"
                  )
                  |> JS.remove_class("hidden", to: "#ai-credential-api-key-show")
                  |> JS.add_class("hidden", to: "#ai-credential-api-key-hide")
                }
                class="hidden absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"
                  />
                </svg>
              </button>
            </div>
            <p
              :for={{msg, opts} <- @form[:api_key].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
          </div>

          <div>
            <label class="flex items-center gap-3 cursor-pointer">
              <input
                type="hidden"
                name="ai_credential[sovereign]"
                value="false"
              />
              <input
                type="checkbox"
                name="ai_credential[sovereign]"
                value="true"
                checked={@form[:sovereign].value in [true, "true"]}
                class="sr-only peer"
              />
              <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm relative">
              </div>
              <span class="font-mono text-[0.78rem] text-black/70">Sovereign credential</span>
            </label>
          </div>

          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Description
            </label>
            <textarea
              name="ai_credential[description]"
              rows="3"
              class="w-full font-mono text-[0.84rem] text-black border border-black/10 rounded-xl px-4 py-3 bg-[#fafafa]"
            >{@form[:description].value}</textarea>
          </div>

          <div class="flex items-center justify-between gap-3 pt-2">
            <button
              :if={@action == :edit}
              type="button"
              phx-click="open_delete_ai_credential_confirm"
              class="font-mono text-[0.8rem] px-4 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50"
            >
              Delete credential
            </button>

            <div class="ml-auto flex items-center gap-3">
              <button
                type="button"
                phx-click="close_ai_credential_modal"
                class="font-mono text-[0.8rem] px-4 py-2 rounded-lg border border-black/10 text-black/60 hover:bg-black/[0.04]"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="font-mono text-[0.8rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3]"
              >
                Save credential
              </button>
            </div>
          </div>
        </.form>

        <ZaqWeb.Components.BOModal.confirm_dialog
          :if={@delete_confirm_modal}
          id="ai-credential-delete-confirm"
          cancel_event="cancel_delete_ai_credential"
          confirm_event="confirm_delete_ai_credential"
          title="Delete AI Credential?"
          message="This action removes the credential. Deletion is blocked if the credential is currently in use."
          confirm_label="Delete"
          cancel_label="Cancel"
        />
      </div>
    </div>
    """
  end
end
