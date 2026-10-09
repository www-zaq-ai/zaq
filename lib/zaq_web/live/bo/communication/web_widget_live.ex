defmodule ZaqWeb.Live.BO.Communication.WebWidgetLive do
  @moduledoc "BO management of web widgets through confidential Engine domain events."

  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:channels]}

  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Live.BO.AI.BOActor
  alias ZaqWeb.Live.BO.Communication.IngressStatusUI

  @health_refresh_ms 15_000
  @policy_fields ~w(identity_issuer identity_audience same_site)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/bo/channels/retrieval/web_widget")
      |> assign(:page_title, "Web Widget")
      |> assign(:configs, [])
      |> assign(:selected, nil)
      |> assign(:modal_open, false)
      |> assign(:expanded_script_id, nil)
      |> assign(:base_url, nil)
      |> assign(:adapter, {:error, :channels_unavailable})
      |> assign(:snippet, {:error, :selection_required})
      |> assign(:authentication_key, nil)
      |> assign(:errors, %{})
      |> assign(:recovery_message, nil)
      |> assign(:ingress_statuses, %{})
      |> assign(:changed_settings, MapSet.new())
      |> assign(:health_timer, nil)
      |> assign(:form, to_form(default_params(), as: :widget))
      |> assign(:agent_options, agent_options(socket))

    {:ok, reload(socket, nil)}
  end

  @impl true
  def handle_info(:refresh_widget_statuses, socket) do
    {:noreply, refresh_health(socket)}
  end

  @impl true
  def handle_async(:widget_statuses, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:configs, result.configs)
     |> assign(:ingress_statuses, result.statuses)
     |> assign(:base_url, result.base_url)
     |> assign(:adapter, result.adapter)
     |> schedule_health_refresh()}
  end

  def handle_async(:widget_statuses, _failure, socket) do
    statuses = Map.new(socket.assigns.configs, &{&1.id, unknown_health()})
    {:noreply, socket |> assign(:ingress_statuses, statuses) |> schedule_health_refresh()}
  end

  @impl true
  def handle_event("new_connector", _params, socket),
    do: {:noreply, socket |> reload(:new) |> assign(:modal_open, true)}

  def handle_event("select_connector", %{"id" => id}, socket),
    do: {:noreply, socket |> reload(id) |> assign(:modal_open, true)}

  def handle_event("close_modal", _params, socket),
    do: {:noreply, socket |> clear_key() |> assign(:modal_open, false)}

  def handle_event("toggle_script", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.configs, &(to_string(&1.id) == id)) do
      nil -> {:noreply, failure(socket, :connector_not_found)}
      config -> {:noreply, toggle_script(socket, config.id)}
    end
  end

  def handle_event("reload_configuration", _params, socket),
    do: {:noreply, socket |> clear_flash() |> reload(selected_id(socket))}

  def handle_event("validate", %{"widget" => params} = event, socket) do
    changed =
      case Map.get(event, "_target") do
        ["widget", field] when field in @policy_fields ->
          MapSet.put(socket.assigns.changed_settings, field)

        _ ->
          socket.assigns.changed_settings
      end

    {:noreply,
     socket
     |> assign(:changed_settings, changed)
     |> assign(:form, to_form(Map.merge(socket.assigns.form.params, params), as: :widget))}
  end

  def handle_event("save", %{"widget" => params}, socket) do
    socket =
      assign(socket, :form, to_form(Map.merge(socket.assigns.form.params, params), as: :widget))

    params = preserve_legacy_settings(params, socket)

    params =
      if Map.has_key?(params, "allowed_domains"),
        do: Map.update!(params, "allowed_domains", &split_origins/1),
        else: params

    request = %{
      op: :save,
      id: selected_id(socket),
      revision: revision(socket),
      params: params
    }

    {:noreply, save_configuration(socket, request, "Configuration saved.")}
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.configs, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, failure(socket, :connector_not_found)}

      config ->
        request = %{
          op: :save,
          id: config.id,
          revision: config.revision,
          params: %{"enabled" => !config.enabled}
        }

        socket =
          socket
          |> clear_key()
          |> assign(:selected, config)
          |> assign(:form, to_form(form_params(config), as: :widget))

        message = if config.enabled, do: "Configuration disabled.", else: "Configuration enabled."
        {:noreply, save_configuration(socket, request, message)}
    end
  end

  def handle_event(event, _params, socket) when event in ["generate_key", "rotate_key"] do
    op = if event == "generate_key", do: :generate_key, else: :rotate_key
    request = %{op: op, id: selected_id(socket), revision: revision(socket)}

    case settings(socket, request) do
      {:ok, result} ->
        {:noreply,
         socket
         |> saved(result, "Key generated. Copy it now and securely provision your host backend.")
         |> assign(:authentication_key, result.authentication_key)}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, clear_key(socket)}

  def handle_event("archive", _params, socket) do
    request = %{
      channel_config_id: selected_id(socket),
      provider: "web_widget",
      kind: "retrieval",
      revision: revision(socket)
    }

    case dispatch(socket, :engine, :archive_channel_connector, request) do
      {:ok, result} ->
        socket = socket |> reload(nil) |> assign(:modal_open, false)

        message =
          if match?({:pending, _}, result.runtime),
            do: "Configuration archived; runtime cleanup is pending.",
            else: "Configuration archived."

        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  defp reload(socket, id) do
    case settings(socket, %{op: :snapshot, id: id}) do
      {:ok, snapshot} -> apply_snapshot(socket, snapshot)
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp saved(socket, result, message) do
    socket = apply_snapshot(socket, result.snapshot)

    if result.runtime == :synced,
      do: put_flash(socket, :info, message),
      else:
        socket
        |> assign(
          :recovery_message,
          "Configuration saved, but runtime synchronization failed. Reload the configuration, then save again to retry."
        )
        |> put_flash(:error, message <> " Runtime synchronization failed.")
  end

  defp save_configuration(socket, request, message) do
    case settings(socket, request) do
      {:ok, result} -> saved(socket, result, message)
      {:error, {:validation, errors}} -> socket |> clear_key() |> assign(:errors, errors)
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp apply_snapshot(socket, snapshot) do
    socket
    |> clear_key()
    |> assign(:configs, snapshot.configs)
    |> assign(:selected, snapshot.selected)
    |> assign(:base_url, snapshot.base_url)
    |> assign(:adapter, snapshot.adapter)
    |> assign(:errors, %{})
    |> assign(:recovery_message, nil)
    |> assign(:form, to_form(form_params(snapshot.selected), as: :widget))
    |> assign(:expanded_script_id, nil)
    |> assign(:snippet, {:error, :selection_required})
    |> assign(:changed_settings, MapSet.new())
    |> assign(:ingress_statuses, %{})
    |> refresh_health()
  end

  defp preserve_legacy_settings(params, %{assigns: %{selected: nil}}), do: params

  defp preserve_legacy_settings(params, socket) do
    Enum.reduce(@policy_fields, params, fn field, acc ->
      original = Map.get(socket.assigns.selected, policy_key(field))

      if is_nil(original) and Map.get(acc, field) == "" and
           not MapSet.member?(socket.assigns.changed_settings, field),
         do: Map.delete(acc, field),
         else: acc
    end)
  end

  defp refresh_health(socket) do
    socket = cancel_health_timer(socket)

    if connected?(socket) do
      user = socket.assigns.current_user

      start_async(socket, :widget_statuses, fn ->
        {:ok, snapshot} =
          dispatch_user(user, :engine, :widget_connector_settings, %{op: :snapshot, id: :new})

        enabled = Enum.filter(snapshot.configs, & &1.enabled)

        statuses =
          enabled
          |> IngressStatusUI.collect(&fetch_widget_health(user, &1))
          |> Map.new(&{&1.id, &1.status})

        %{
          configs: snapshot.configs,
          statuses: statuses,
          base_url: snapshot.base_url,
          adapter: snapshot.adapter
        }
      end)
    else
      socket
    end
  end

  defp fetch_widget_health(user, config) do
    request = %{provider: "web_widget", channel_config_id: config.id}

    user
    |> dispatch_user(:channels, :channel_ingress_status, request)
    |> IngressStatusUI.normalize_response()
  end

  defp schedule_health_refresh(socket) do
    socket = cancel_health_timer(socket)
    timer = Process.send_after(self(), :refresh_widget_statuses, @health_refresh_ms)
    assign(socket, :health_timer, timer)
  end

  defp cancel_health_timer(socket) do
    if socket.assigns.health_timer, do: Process.cancel_timer(socket.assigns.health_timer)
    assign(socket, :health_timer, nil)
  end

  defp toggle_script(%{assigns: %{expanded_script_id: id}} = socket, id),
    do:
      socket
      |> assign(:expanded_script_id, nil)
      |> assign(:snippet, {:error, :selection_required})

  defp toggle_script(socket, id) do
    socket
    |> clear_key()
    |> assign(:expanded_script_id, id)
    |> assign(:snippet, settings(socket, %{op: :embed_script, id: id}))
  end

  defp selected_id(%{assigns: %{selected: nil}}), do: :new
  defp selected_id(socket), do: socket.assigns.selected.id
  defp revision(%{assigns: %{selected: nil}}), do: nil
  defp revision(socket), do: socket.assigns.selected.revision

  defp clear_key(socket), do: assign(socket, :authentication_key, nil)

  defp default_params do
    Map.merge(WidgetSettings.defaults(), %{
      "name" => "",
      "allowed_domains" => "",
      "agent_id" => "",
      "enabled" => false
    })
  end

  defp form_params(nil), do: default_params()

  defp form_params(selected) do
    %{
      "name" => selected.name,
      "allowed_domains" => Enum.join(selected.allowed_domains, "\n"),
      "agent_id" => selected.agent_id,
      "enabled" => selected.enabled,
      "identity_issuer" => selected.identity_issuer || "",
      "identity_audience" => selected.identity_audience || "",
      "same_site" => selected.same_site || ""
    }
  end

  defp split_origins(value) when is_binary(value),
    do:
      value
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp split_origins(value), do: value

  defp agent_options(socket) do
    agents =
      case dispatch(socket, :agent, :system_config_agent_list_active_agents, %{}) do
        agents when is_list(agents) ->
          Enum.filter(agents, &Map.get(&1, :conversation_enabled, false))

        _ ->
          []
      end

    [{"Use inherited routing", ""}, {"NONE — do not route to an agent", "__none__"}] ++
      Enum.map(agents, &{&1.name, &1.id})
  end

  defp settings(socket, request),
    do: dispatch(socket, :engine, :widget_connector_settings, request)

  defp dispatch(socket, role, action, request) do
    dispatch_user(socket.assigns.current_user, role, action, request)
  end

  defp dispatch_user(user, role, action, request) do
    event =
      Event.new(request, role,
        actor: BOActor.build(user),
        opts: [action: action, confidential: true]
      )

    case NodeRouter.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :service_unavailable}
    end
  rescue
    _error -> {:error, :service_unavailable}
  catch
    _kind, _reason -> {:error, :service_unavailable}
  end

  defp failure(socket, :stale_connector) do
    socket
    |> clear_key()
    |> assign(
      :recovery_message,
      "Configuration changed elsewhere. Reload it before making and saving your changes again."
    )
  end

  defp failure(socket, reason),
    do: socket |> clear_key() |> put_flash(:error, error_message(reason))

  defp error_message(:missing_global_base_url),
    do: "Configure the global base URL in System Configuration first."

  defp error_message(:widget_runtime_not_configured),
    do: "Install and configure the widget adapter before enabling."

  defp error_message(:invalid_request), do: "Invalid configuration request."
  defp error_message(:invalid_agent), do: "Choose a conversation-enabled agent."
  defp error_message(:connector_not_found), do: "Configuration not found or archived."

  defp error_message(:key_already_exists),
    do: "A key already exists. Use Rotate authentication key."

  defp error_message(_reason),
    do: "The operation is unavailable. Reopen the configuration and try again."

  defp adapter_available?({:ok, %{available?: true}}), do: true
  defp adapter_available?(_adapter), do: false

  defp policy_key("identity_issuer"), do: :identity_issuer
  defp policy_key("identity_audience"), do: :identity_audience
  defp policy_key("same_site"), do: :same_site

  defp widget_health(config, statuses) do
    if config.enabled,
      do: Map.get(statuses, config.id, %{status: :pending, summary: "Checking widget readiness"}),
      else: %{status: :disabled, summary: "Disabled"}
  end

  defp unknown_health, do: %{status: :unknown, summary: "Widget readiness cannot be verified"}

  defp policy_hint(selected, statuses, key) do
    effective =
      if selected,
        do: get_in(statuses, [selected.id, :effective_settings, key]),
        else: nil

    case effective do
      %{value: value, source: source} when is_binary(value) ->
        "Effective: #{value} (#{source}). Saved changes require adapter support and synchronization."

      _ ->
        "Effective value is unverified. Blank legacy fields preserve existing adapter configuration."
    end
  end

  attr :message, :string, required: true

  defp configuration_recovery(assigns) do
    ~H"""
    <div class="space-y-3">
      <ZaqWeb.Components.DesignSystem.FeedbackBanner.feedback_banner
        id="widget-recovery-error"
        kind={:error}
        message={@message}
        auto_dismiss={false}
        dismissible={false}
      />
      <ZaqWeb.Components.DesignSystem.Button.button
        id="reload-widget-config"
        variant={:secondary}
        phx-click="reload_configuration"
      >Reload configuration</ZaqWeb.Components.DesignSystem.Button.button>
    </div>
    """
  end

  defp snippet_message({:error, :missing_global_base_url}),
    do: "Configure the global base URL to generate the installation script."

  defp snippet_message({:error, :selection_required}),
    do: "Save the configuration to generate its installation script."

  defp snippet_message(_result), do: "The adapter's installation script is unavailable."
end
