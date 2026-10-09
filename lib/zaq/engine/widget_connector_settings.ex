defmodule Zaq.Engine.WidgetConnectorSettings do
  @moduledoc """
  Engine-owned management boundary for web widget connector configurations.

  The confidential BO Action authenticates the caller. This context fixes the
  provider/kind, locks mutations against an existing lifecycle revision, uses
  ChannelConfig encryption and IncomingMessageRouting, and returns allowlisted
  snapshots. Only successful key generation/rotation returns a plaintext key,
  once, for the administrator to provision to the host backend. Runtime failures
  after persistence are pending warnings, never false rollbacks.
  """

  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle, IncomingMessageRouting}
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.System, as: SystemConfig
  alias Zaq.Utils.ParseUtils

  @provider "web_widget"
  @fields ~w(name enabled display_name allowed_domains agent_id identity_issuer identity_audience same_site)

  @doc "Executes an authenticated management request through the owning BO Action."
  def execute(request, opts \\ [])

  def execute(%{op: :snapshot} = request, opts),
    do: snapshot(Map.get(request, :id), opts)

  def execute(%{op: :save, params: params} = request, opts) when is_map(params) do
    with :ok <- validate_params(params),
         :ok <- enablement(params, opts),
         {:ok, saved} <- mutate(request, &persist(&1, params, opts)) do
      result(saved, opts)
    end
  end

  def execute(%{op: op} = request, opts) when op in [:generate_key, :rotate_key] do
    key = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, saved} <- mutate(request, &persist_key(&1, op, key)),
         {:ok, result} <- result(saved, opts) do
      {:ok, Map.put(result, :authentication_key, key)}
    end
  end

  def execute(%{op: :embed_script, id: id}, opts) do
    with {:ok, config} <- selected(id),
         base_url when is_binary(base_url) and base_url != "" <-
           SystemConfig.get_global_base_url() do
      channels(%{op: :embed_script, widget_id: config.id, base_url: base_url}, opts)
    else
      nil -> {:error, :missing_global_base_url}
      {:error, _} = error -> error
      _ -> {:error, :missing_global_base_url}
    end
  end

  def execute(_request, _opts), do: {:error, :invalid_request}

  defp snapshot(id, opts) do
    configs = ChannelConfig.list_by_provider(@provider) |> Enum.filter(&is_nil(&1.archived_at))
    id = if is_nil(id), do: first_id(configs), else: id

    with {:ok, config} <- selected(id) do
      {:ok,
       %{
         configs: Enum.map(configs, &projection/1),
         selected: if(config.id, do: projection(config)),
         base_url: SystemConfig.get_global_base_url(),
         adapter: channels(%{op: :status, widget_id: config.id}, opts)
       }}
    end
  end

  defp first_id([]), do: :new
  defp first_id([config | _]), do: config.id

  defp selected(:new),
    do: {:ok, %ChannelConfig{provider: @provider, kind: "retrieval", enabled: false}}

  defp selected(id) do
    with {:ok, id} when id > 0 <- ParseUtils.parse_int_strict(id),
         %ChannelConfig{provider: @provider, kind: "retrieval", archived_at: nil} = config <-
           ChannelConfig.get(id) do
      {:ok, config}
    else
      _ -> {:error, :connector_not_found}
    end
  end

  defp mutate(%{op: :save, id: :new}, fun) do
    Repo.transaction(fn ->
      {:ok, config} = selected(:new)
      apply_mutation(config, fun)
    end)
  end

  defp mutate(%{id: id, revision: expected}, fun) when is_binary(expected) do
    Repo.transaction(fn ->
      with {:ok, config} <- selected(id),
           %ChannelConfig{} = locked <- Repo.get(ChannelConfig, config.id, lock: "FOR UPDATE"),
           nil <- locked.archived_at,
           {:ok, %{revision: ^expected}} <-
             ConnectorLifecycle.context(locked.id, @provider, "retrieval") do
        apply_mutation(locked, fun)
      else
        {:ok, _descriptor} -> Repo.rollback(:stale_connector)
        _ -> Repo.rollback(:connector_not_found)
      end
    end)
  end

  defp mutate(_request, _fun), do: {:error, :invalid_request}

  defp apply_mutation(config, fun) do
    case fun.(config) do
      {:ok, saved} -> {if(config.id, do: config), saved}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist(config, params, opts) do
    settings =
      initial_settings(config)
      |> Map.drop(["stylesheet_url", :stylesheet_url])
      |> put_setting(params, "display_name")
      |> put_setting(params, "allowed_domains")
      |> put_setting(params, "identity_issuer")
      |> put_setting(params, "identity_audience")
      |> put_setting(params, "same_site")

    attrs = params |> Map.take(["name", "enabled"]) |> Map.put("settings", settings)

    with :ok <-
           enablement(
             Map.put(params, "enabled", Map.get(params, "enabled", config.enabled)),
             opts
           ),
         {:ok, saved} <- persist_changeset(ChannelConfig.changeset(config, attrs)),
         :ok <- persist_routing(saved.id, params) do
      {:ok, saved}
    end
  end

  defp initial_settings(%ChannelConfig{id: nil, settings: settings}),
    do: Map.merge(WidgetSettings.defaults(), settings || %{})

  defp initial_settings(config), do: config.settings || %{}

  defp put_setting(settings, params, key) do
    case Map.fetch(params, key) do
      :error -> settings
      {:ok, ""} when key == "display_name" -> Map.delete(settings, key)
      {:ok, value} -> Map.put(settings, key, value)
    end
  end

  defp persist_key(%ChannelConfig{id: nil}, _op, _key), do: {:error, :selection_required}

  defp persist_key(config, op, key) do
    if op == :generate_key and key_present?(config) do
      {:error, :key_already_exists}
    else
      settings =
        Map.put(config.settings || %{}, "key_rotated_at", DateTime.to_iso8601(DateTime.utc_now()))

      config |> ChannelConfig.changeset(%{token: key, settings: settings}) |> persist_changeset()
    end
  end

  defp persist_changeset(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, config} ->
        {:ok, config}

      {:error, invalid} ->
        errors = Ecto.Changeset.traverse_errors(invalid, fn {message, _metadata} -> message end)
        {:error, {:validation, errors}}
    end
  end

  defp persist_routing(id, %{"agent_id" => choice}) do
    command = routing_command(id, choice)

    case IncomingMessageRouting.apply_rule_commands([command]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_agent}
    end
  end

  defp persist_routing(_id, _params), do: :ok

  defp routing_command(id, choice) when choice in [nil, ""],
    do: %{channel_config_id: id, routing_mode: :clear}

  defp routing_command(id, "__none__"), do: %{channel_config_id: id, routing_mode: :none}

  defp routing_command(id, choice),
    do: %{channel_config_id: id, routing_mode: :agent, configured_agent_id: choice}

  defp enablement(%{"enabled" => value}, opts) do
    case Ecto.Type.cast(:boolean, value) do
      {:ok, true} -> enablement_prerequisites(opts)
      {:ok, false} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp enablement(_params, _opts), do: :ok

  defp enablement_prerequisites(opts) do
    case SystemConfig.get_global_base_url() do
      nil -> {:error, :missing_global_base_url}
      _ -> adapter_available(opts)
    end
  end

  defp adapter_available(opts) do
    case channels(%{op: :status, widget_id: nil}, opts) do
      {:ok, %{available?: true}} -> :ok
      _ -> {:error, :widget_runtime_not_configured}
    end
  end

  defp validate_params(params) do
    if Enum.all?(Map.keys(params), &(&1 in @fields)),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp result({before, saved}, opts) do
    runtime = sync_runtime(before, saved, opts)

    with {:ok, snapshot} <- snapshot(saved.id, opts) do
      {:ok, %{snapshot: snapshot, runtime: runtime}}
    end
  end

  defp projection(config) do
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, @provider, "retrieval")

    %{
      id: config.id,
      widget_id: config.id,
      name: config.name,
      enabled: config.enabled,
      display_name: Map.get(config.settings || %{}, "display_name", ""),
      allowed_domains: Map.get(config.settings || %{}, "allowed_domains", []),
      identity_issuer: Map.get(config.settings || %{}, "identity_issuer"),
      identity_audience: Map.get(config.settings || %{}, "identity_audience"),
      same_site: Map.get(config.settings || %{}, "same_site"),
      key_present?: key_present?(config),
      key_rotated_at: Map.get(config.settings || %{}, "key_rotated_at"),
      revision: descriptor.revision,
      agent_id: agent_choice(config.id)
    }
  end

  defp key_present?(config), do: is_binary(config.token) and config.token != ""

  defp agent_choice(id) do
    case IncomingMessageRouting.get_rule(%{channel_config_id: id}) do
      %{routing_mode: :none} -> "__none__"
      %{routing_mode: :agent, configured_agent_id: agent_id} -> to_string(agent_id)
      _ -> ""
    end
  end

  defp sync_runtime(before, saved, opts) do
    request = %{before_config: runtime_config(before), after_config: runtime_config(saved)}

    case dispatch(:sync_channel_runtime, request, opts) do
      :ok -> :synced
      {:ok, _} -> :synced
      _ -> {:pending, :runtime_sync_failed}
    end
  end

  defp runtime_config(nil), do: nil

  defp runtime_config(config) do
    config
    |> ChannelConfig.to_runtime_config()
    |> Map.from_struct()
    |> Map.take([:id, :name, :provider, :kind, :enabled, :token, :settings])
  end

  defp channels(request, opts), do: dispatch(:widget_adapter_setup, request, opts)

  defp dispatch(action, request, opts) do
    router = Keyword.get(opts, :node_router, NodeRouter)

    event =
      Event.new(request, :channels,
        opts:
          Keyword.take(opts, [:config, :runtime_module]) ++ [action: action, confidential: true]
      )

    case router.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :channels_unavailable}
    end
  rescue
    _error -> {:error, :channels_unavailable}
  catch
    _kind, _reason -> {:error, :channels_unavailable}
  end
end
