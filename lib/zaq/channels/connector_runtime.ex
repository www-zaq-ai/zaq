defmodule Zaq.Channels.ConnectorRuntime do
  @moduledoc """
  Owns provider configuration-transition semantics and runtime reconciliation.

  Channels alone interprets provider preparation and runtime failures. Engine receives
  a confirmed configuration transition (runtime complete or pending) or a bounded
  error. Activation can request an after-persistence continuation so saved
  credential eligibility is committed before runtime access. No persistence occurs here.
  """

  alias Zaq.Channels.{Bridge, CommunicationBridge, DataSourceBridge}
  alias Zaq.ConnectorConfig.Settings
  alias Zaq.Engine.ChannelConfig
  alias Zaq.{Event, NodeRouter}

  @type outcome ::
          {:ok,
           %{
             transition: :confirmed,
             target: map(),
             runtime: :complete | {:pending, atom()},
             continuation: :none | :after_persist
           }}
          | {:error, atom()}

  @doc "Reloads saved bindings through Engine before startup; legacy runtime targets pass through."
  @spec current_config(Bridge.runtime_target()) ::
          {:ok, Bridge.runtime_target()} | {:error, term()}
  def current_config(%{id: id, provider: _, kind: _, settings: settings} = config)
      when is_integer(id) and id > 0 and is_map(settings) do
    if Settings.saved_binding?(config), do: resolve_current(config), else: {:ok, config}
  end

  def current_config(config), do: {:ok, config}

  defp resolve_current(%{id: id, provider: provider, kind: kind} = config) do
    event =
      Event.new(%{channel_config_id: id, provider: provider, kind: kind}, :engine,
        opts: [action: :connector_runtime_context, confidential: true, connector_runtime: true]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, current} -> {:ok, Map.merge(config, current)}
      {:error, _} = error -> error
      _ -> {:error, :connector_unavailable}
    end
  end

  @doc "Tears down ingress using supplied credentials, without configuration persistence."
  def teardown_ingress(%{kind: "data_source"}, _opts), do: {:ok, :not_required}

  def teardown_ingress(%{id: id, provider: provider} = config, opts) do
    case Bridge.provider_config(provider) do
      %{ingress_mode: :webhook} ->
        module = Keyword.get(opts, :communication_bridge_module, CommunicationBridge)

        case module.delete_ingress_subscription(config, %{strict: true, config_id: id}) do
          {:ok, %{deleted: false, reason: reason}} -> {:ok, {:warning, reason}}
          {:ok, _} -> {:ok, :deleted}
          {:error, :unsupported} -> {:ok, :unsupported}
          {:error, reason} -> {:error, {:ingress_teardown_failed, reason}}
          other -> {:error, {:ingress_teardown_failed, {:unexpected_response, other}}}
        end

      _ ->
        {:ok, :not_required}
    end
  end

  def teardown_ingress(_config, _opts), do: {:error, :invalid_request}

  @doc "Confirms a configuration transition without exposing provider stages to Engine."
  @spec sync_runtime(map(), term(), keyword()) :: outcome()
  def sync_runtime(
        %{before_config: before, after_config: after_config, phase: phase} = request,
        actor,
        opts
      )
      when phase in [:before_persist, :after_persist] do
    if same_scope?(before, after_config) and
         Map.get(request, :intent, :set_enabled) in [:archive, :set_enabled] do
      sync_phase(request, actor, opts)
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def sync_runtime(_, _, _), do: {:error, :invalid_request}

  defp same_scope?(
         %{id: id, provider: provider, kind: kind, enabled: before},
         %{id: id, provider: provider, kind: kind, enabled: after_enabled}
       )
       when is_integer(id) and id > 0 and is_binary(provider) and is_binary(kind) and
              is_boolean(before) and is_boolean(after_enabled),
       do: true

  defp same_scope?(_, _), do: false

  defp sync_phase(%{phase: :before_persist, after_config: %{enabled: true} = config}, _, _),
    do: confirmed(config, {:pending, :configuration_required}, :after_persist)

  defp sync_phase(
         %{phase: :before_persist, before_config: before, after_config: config} = request,
         actor,
         opts
       ) do
    case prepare_disable(before, config, actor, opts) do
      :ok ->
        finish_transition(
          config,
          reconcile_runtime(before, config, opts, Map.get(request, :intent, :set_enabled))
        )

      {:error, {:disable_failed, reason}} ->
        {:error, public_reason(reason)}
    end
  end

  defp sync_phase(
         %{phase: :after_persist, before_config: before, after_config: %{enabled: true} = config},
         actor,
         opts
       ),
       do: activate(before, config, actor, opts)

  defp sync_phase(_, _, _), do: {:error, :invalid_request}

  @doc "Runs the legacy before/after sync using the same provider preparation."
  def sync_config_runtime(before, after_config, actor, opts) do
    runtime = runtime_module(after_config, opts)

    with :ok <- prepare_disable(before, after_config, actor, opts) do
      runtime.sync_config_runtime(
        ChannelConfig.to_runtime_config(before),
        ChannelConfig.to_runtime_config(after_config)
      )
    end
  end

  defp confirmed(config, runtime, continuation),
    do:
      {:ok,
       %{
         transition: :confirmed,
         target: Map.take(config, [:id, :provider, :kind, :enabled]),
         runtime: runtime,
         continuation: continuation
       }}

  defp runtime_result(:ok), do: :complete
  defp runtime_result({:ok, _}), do: :complete
  defp runtime_result({:error, reason}), do: {:pending, public_reason(reason)}
  defp runtime_result(_), do: {:pending, :invalid_response}

  defp activate(before, after_config, actor, opts) do
    case authorize_activation(after_config, actor, opts) do
      :ok ->
        confirmed(
          after_config,
          runtime_result(sync_config_runtime(before, after_config, actor, opts)),
          :none
        )

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authorize_activation(%{provider: provider}, actor, opts) do
    case Bridge.provider_config(provider) do
      %{ingress_mode: :linked_device} ->
        if match?(%{user_id: id} when is_integer(id) and id > 0, actor) and
             opts[:skip_permissions] == true, do: :ok, else: {:error, :unauthorized}

      _ ->
        :ok
    end
  end

  defp finish_transition(_config, {:error, {:ingress_teardown_failed, reason}}),
    do: {:error, public_reason(reason)}

  defp finish_transition(config, result), do: confirmed(config, runtime_result(result), :none)

  defp reconcile_runtime(before, after_config, opts, :archive),
    do: stop_runtime(before, after_config, opts)

  defp reconcile_runtime(%{enabled: true} = before, after_config, opts, :set_enabled),
    do: runtime_module(after_config, opts).sync_config_runtime(before, after_config)

  defp reconcile_runtime(before, after_config, opts, :set_enabled),
    do: stop_runtime(before, after_config, opts)

  defp public_reason(reason) when reason in [:unauthorized, :unsupported, :conflict], do: reason

  defp public_reason(reason)
       when reason in [
              :offline,
              :unavailable,
              :not_running,
              :channels_unavailable,
              :preparation_unavailable,
              :logout_unavailable
            ],
       do: :unavailable

  defp public_reason(_), do: :failed

  defp runtime_module(config, opts) do
    default =
      if Map.get(config, :kind) == "data_source", do: DataSourceBridge, else: CommunicationBridge

    key =
      if Map.get(config, :kind) == "data_source",
        do: :data_source_runtime_module,
        else: :communication_runtime_module

    Keyword.get(opts, :runtime_module, Keyword.get(opts, key, default))
  end

  defp prepare_disable(%{enabled: true} = before, %{enabled: false} = after_config, actor, opts) do
    runtime = runtime_module(after_config, opts)

    result =
      with {:module, _} <- Code.ensure_loaded(runtime) do
        if function_exported?(runtime, :before_disable, 3),
          do: runtime.before_disable(ChannelConfig.to_runtime_config(before), actor, opts),
          else: :ok
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:disable_failed, reason}}
      other -> {:error, {:disable_failed, {:unexpected_response, other}}}
    end
  rescue
    _ -> {:error, {:disable_failed, :preparation_unavailable}}
  catch
    :exit, _ -> {:error, {:disable_failed, :logout_unavailable}}
  end

  defp prepare_disable(_, _, _, _), do: :ok

  defp stop_runtime(
         %{id: id, provider: provider, kind: kind},
         %{id: id, provider: provider, kind: kind, enabled: false} = after_config,
         opts
       ) do
    with {:ok, bridge} <- runtime_bridge(provider, kind, opts),
         true <-
           (Code.ensure_loaded?(bridge) and function_exported?(bridge, :stop_runtime, 1)) ||
             {:error, :unsupported} do
      bridge.stop_runtime(after_config)
    end
  end

  defp runtime_bridge(provider, kind, opts) do
    key =
      if kind == "data_source",
        do: :data_source_runtime_module,
        else: :communication_runtime_module

    case Keyword.get(opts, key) do
      nil -> Bridge.resolve_bridge(provider)
      module -> {:ok, module}
    end
  end
end
