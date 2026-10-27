defmodule Zaq.Engine.ConnectorLifecycle do
  @moduledoc """
  Owns connector configuration persistence and archive commands across service boundaries.

  Engine owns connector scope, revision validation, archive persistence and
  data-source watch ordering/cleanup. Channels consumes resolved configurations
  for provider ingress teardown and runtime sync, without database access.
  Channels owns transition semantics and returns confirmation or a bounded error.
  One generic interpreter persists confirmed desired configurations
  and follows requested after-persistence continuations. Runtime pending prevents
  archival; failed pre-persistence calls leave configuration unchanged.
  Post-archive watch cleanup may remain pending.

  Startup rechecks current eligibility through a confidential Engine runtime event.
  No database row lock is held across Channels or credential-storage callbacks.
  """

  alias Zaq.Engine.{ChannelConfig, DataSources}
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  @revision_fields [
    :id,
    :provider,
    :kind,
    :enabled,
    :archived_at,
    :name,
    :url,
    :token,
    :settings,
    :notification_default,
    :updated_at
  ]

  @doc "Returns a secret-free descriptor for an exactly scoped connector."
  def context(id, provider, kind) do
    with {:ok, id} <- cast_id(id),
         %ChannelConfig{} = config <- ChannelConfig.get(id),
         :ok <- validate_scope(config, provider, kind) do
      {:ok, descriptor(config)}
    else
      _ -> {:error, :connector_not_found}
    end
  end

  @doc "Archives one exactly scoped connector and returns an ID-only staged result."
  def archive(request, actor, opts \\ [])

  def archive(request, actor, opts) when is_map(request) and is_list(opts),
    do: do_archive(request, actor, opts)

  def archive(_request, _actor, _opts), do: {:error, :invalid_request}

  @doc "Executes a trusted Engine lifecycle command."
  def execute(%{operation: :context, request: request}, actor, _opts) do
    if match?(%{user_id: id} when is_integer(id) and id > 0, actor) do
      context(request[:channel_config_id], request[:provider], request[:kind])
    else
      {:error, :unauthorized}
    end
  end

  def execute(%{operation: :set_enabled, request: request}, actor, opts),
    do: set_enabled(request, actor, opts)

  def execute(_, _, _), do: {:error, :invalid_request}

  defp set_enabled(
         %{
           channel_config_id: id,
           provider: provider,
           kind: kind,
           enabled: enabled,
           revision: expected
         },
         actor,
         opts
       )
       when is_boolean(enabled) and is_binary(expected) and is_binary(provider) and
              is_binary(kind) do
    with true <-
           match?(%{user_id: id} when is_integer(id) and id > 0, actor) || {:error, :unauthorized},
         {:ok, id} <- cast_id(id),
         %ChannelConfig{archived_at: nil} = config <- ChannelConfig.get(id),
         :ok <- validate_scope(config, provider, kind),
         :ok <- validate_revision(config, expected),
         :ok <- authorize_enable(config, enabled, opts) do
      set_enabled_current(config, enabled, expected, actor, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :connector_not_found}
    end
  end

  defp set_enabled(_, _, _), do: {:error, :invalid_request}

  defp authorize_enable(%{provider: provider}, true, opts)
       when provider in [:whatsapp, "whatsapp"] do
    if opts[:skip_permissions] == true,
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_enable(_, _, _), do: :ok

  defp set_enabled_current(config, enabled, expected, actor, opts) do
    with {:ok, saved, runtime} <- transition_config(config, enabled, expected, actor, opts) do
      {:ok, enabled_result(saved, present_runtime(runtime))}
    end
  end

  defp enabled_result(config, runtime),
    do: %{channel_config_id: config.id, enabled: config.enabled, runtime: runtime}

  defp transition_config(before, enabled, expected, actor, opts) do
    desired = %{before | enabled: enabled}

    with {:ok, result} <- transition_call(before, desired, expected, :before_persist, actor, opts),
         {:ok, saved} <- persist_enabled(before.id, expected, enabled) do
      {:ok, saved, continue_transition(result, before, saved, actor, opts)}
    end
  end

  defp continue_transition(%{continuation: :after_persist}, before, saved, actor, opts) do
    case transition_call(before, saved, revision(saved), :after_persist, actor, opts) do
      {:ok, completed} -> completed.runtime
      {:error, reason} -> {:pending, reason}
    end
  end

  defp continue_transition(%{runtime: runtime}, _, _, _, _), do: runtime

  defp transition_call(before, desired, expected, phase, actor, opts) do
    response =
      channels_call(
        Keyword.get(opts, :router, NodeRouter),
        :connector_sync_runtime,
        %{
          before_config: runtime_config(before),
          after_config: runtime_config(desired),
          revision: expected,
          phase: phase,
          intent: Keyword.get(opts, :transition_intent, :set_enabled)
        },
        actor,
        opts
      )

    target = Map.take(desired, [:id, :provider, :kind, :enabled])
    validate_transition(response, target, phase)
  end

  @transition_reasons [
    :configuration_required,
    :unavailable,
    :failed,
    :unsupported,
    :unauthorized,
    :conflict,
    :invalid_request,
    :invalid_response
  ]

  defp validate_transition(
         {:ok,
          %{transition: :confirmed, target: target, runtime: runtime, continuation: next} = result},
         target,
         phase
       ) do
    valid_runtime =
      runtime == :complete or
        match?({:pending, reason} when reason in @transition_reasons, runtime)

    valid_next =
      next == :none or
        (next == :after_persist and phase == :before_persist and match?({:pending, _}, runtime))

    if valid_runtime and valid_next,
      do: {:ok, result},
      else: {:error, :invalid_response}
  end

  defp validate_transition({:error, reason} = error, _, _) when reason in @transition_reasons,
    do: error

  defp validate_transition({:error, _}, _, _), do: {:error, :unavailable}
  defp validate_transition(_, _, _), do: {:error, :invalid_response}

  defp present_runtime(:complete), do: :ok
  defp present_runtime({:pending, reason}), do: {:error, reason}

  defp do_archive(request, actor, opts) do
    router = Keyword.get(opts, :router, NodeRouter)
    data_sources = Keyword.get(opts, :data_sources_module, DataSources)

    with %{channel_config_id: id, provider: provider, kind: kind} <- request,
         {:ok, id} <- cast_id(id),
         %ChannelConfig{} = before <- ChannelConfig.get(id),
         :ok <- validate_scope(before, provider, kind),
         context = descriptor(before),
         expected = Map.get(request, :revision, context.revision),
         :ok <- validate_revision(before, expected),
         {:ok, watches} <- stop_watches(context, data_sources),
         {:ok, ingress} <- teardown_ingress(before, router, actor, opts),
         %ChannelConfig{} = before <- ChannelConfig.get(id),
         :ok <- validate_revision(before, expected),
         {:ok, disabled} <- disable_before_archive(before, expected, actor, opts),
         {:ok, status, _archived} <- persist_archive(disabled, revision(disabled)) do
      archived = %{
        channel_config_id: id,
        status: status,
        ingress: ingress,
        runtime: :synced
      }

      {:ok,
       archived
       |> Map.put(:watch_teardown, watches)
       |> Map.put(:cleanup, reconcile_watches(context, archived, data_sources))}
    else
      {:error, :connector_mismatch} -> {:error, :connector_not_found}
      {:error, _} = error -> error
      _ -> {:error, :connector_not_found}
    end
  end

  defp disable_before_archive(config, expected, actor, opts) do
    with {:ok, disabled, runtime} <-
           transition_config(
             config,
             false,
             expected,
             actor,
             Keyword.put(opts, :transition_intent, :archive)
           ) do
      case runtime do
        {:pending, reason} -> {:error, {:runtime_pending, reason}}
        :complete -> {:ok, disabled}
      end
    end
  end

  @doc "Resolves a fresh enabled connector for explicitly trusted runtime startup."
  @spec runtime_context(map()) :: {:ok, map()} | {:error, atom()}
  def runtime_context(%{channel_config_id: id, provider: provider, kind: kind}) do
    with {:ok, id} <- cast_id(id),
         %ChannelConfig{enabled: true, archived_at: nil} = config <- ChannelConfig.get(id),
         :ok <- validate_scope(config, provider, kind) do
      {:ok, runtime_config(config)}
    else
      _ -> {:error, :connector_unavailable}
    end
  end

  def runtime_context(_), do: {:error, :invalid_request}

  defp persist_enabled(id, expected, enabled?) do
    Repo.transaction(fn ->
      case Repo.get(ChannelConfig, id, lock: "FOR UPDATE") do
        %ChannelConfig{} = current ->
          persist_enabled_current(current, expected, enabled?)

        _ ->
          Repo.rollback(:connector_not_found)
      end
    end)
  end

  defp persist_enabled_current(current, expected, enabled?) do
    with :ok <- validate_revision(current, expected),
         {:ok, saved} <- current |> Ecto.Changeset.change(enabled: enabled?) |> Repo.update() do
      saved
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp stop_watches(%{kind: "data_source", archived?: false, channel_config_id: id}, module) do
    case module.stop_config_watch_channels(id) do
      {:ok, count} -> {:ok, %{status: :stopped, count: count}}
      {:error, failures} -> {:error, {:watch_teardown_failed, failures}}
    end
  end

  defp stop_watches(%{kind: "data_source", archived?: true}, _module),
    do: {:ok, %{status: :already_archived, count: 0}}

  defp stop_watches(_context, _module), do: {:ok, %{status: :not_required, count: 0}}

  defp reconcile_watches(%{kind: "data_source", channel_config_id: id}, archived, module)
       when archived.status in [:archived, :already_archived] do
    case module.reconcile_archived_config_watches(id) do
      {:ok, count} -> %{status: :scheduled, count: count}
      {:error, reason} -> %{status: :pending, reason: reason}
    end
  end

  defp reconcile_watches(_context, _archived, _module),
    do: %{status: :not_required, count: 0}

  defp descriptor(config) do
    %{
      channel_config_id: config.id,
      provider: config.provider,
      kind: config.kind,
      archived?: not is_nil(config.archived_at),
      revision: revision(config)
    }
  end

  defp validate_scope(config, provider, kind) do
    if config.provider == to_string(provider) and config.kind == to_string(kind),
      do: :ok,
      else: {:error, :connector_mismatch}
  end

  defp validate_revision(config, expected) do
    if revision(config) == expected, do: :ok, else: {:error, :stale_connector}
  end

  defp teardown_ingress(%ChannelConfig{archived_at: %DateTime{}}, _router, _actor, _opts),
    do: {:ok, :already_archived}

  defp teardown_ingress(%ChannelConfig{enabled: false}, _router, _actor, _opts),
    do: {:ok, :already_disabled}

  defp teardown_ingress(config, router, actor, opts) do
    case channels_call(
           router,
           :connector_teardown_ingress,
           %{config: runtime_config(config)},
           actor,
           opts
         ) do
      {:ok, _} = ok -> ok
      {:error, {:ingress_teardown_failed, _}} = error -> error
      {:error, reason} -> {:error, {:ingress_teardown_failed, reason}}
      other -> {:error, {:ingress_teardown_failed, {:unexpected_response, other}}}
    end
  end

  defp persist_archive(before, expected_revision) do
    Repo.transaction(fn ->
      current = Repo.get!(ChannelConfig, before.id, lock: "FOR UPDATE")

      cond do
        revision(current) != expected_revision ->
          Repo.rollback(:stale_connector)

        not is_nil(current.archived_at) ->
          {:already_archived, current}

        true ->
          archive_current(current)
      end
    end)
    |> case do
      {:ok, {status, config}} -> {:ok, status, config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_current(current) do
    case ChannelConfig.archive(current) do
      {:ok, archived} -> {:archived, archived}
      {:error, changeset} -> Repo.rollback({:archive_failed, changeset})
    end
  end

  defp runtime_config(config) do
    config
    |> ChannelConfig.to_runtime_config()
    |> Map.take([:id, :provider, :kind, :name, :url, :token, :enabled, :settings])
  end

  defp revision(config) do
    config
    |> Map.take(@revision_fields)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp cast_id(id) do
    case ParseUtils.parse_int_strict(id) do
      {:ok, value} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp channels_call(router, action, request, actor, opts) do
    event =
      Event.new(request, :channels,
        actor: actor,
        opts: channels_opts(action, opts)
      )

    case router.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :channels_unavailable}
    end
  rescue
    _ -> {:error, :channels_unavailable}
  catch
    :exit, _ -> {:error, :channels_unavailable}
  end

  defp channels_opts(action, opts) do
    forwarded =
      Keyword.take(opts, [
        :communication_bridge_module,
        :communication_runtime_module,
        :data_source_runtime_module,
        :skip_permissions
      ])

    forwarded
    |> Keyword.put(:action, action)
    |> Keyword.put(:confidential, true)
  end
end
