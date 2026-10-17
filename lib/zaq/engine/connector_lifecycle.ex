defmodule Zaq.Engine.ConnectorLifecycle do
  @moduledoc """
  Coordinates connector archive and confirmed disable commands across service boundaries.

  Engine owns connector scope, revision validation, archive persistence and
  data-source watch ordering/cleanup. Channels consumes resolved configurations
  for provider ingress teardown and runtime sync, without database access.
  Archival follows adapter disable preparation, persisted disablement and
  successful runtime shutdown. A shutdown failure leaves the disabled connector
  unarchived for retry; post-archive watch cleanup may remain pending.
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

  def archive(request, actor, opts) when is_map(request) and is_list(opts) do
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
         {:ok, disabled} <- disable_before_archive(before, expected, router, actor, opts),
         :ok <- stop_before_archive(before, disabled, router, actor, opts),
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

  def archive(_request, _actor, _opts), do: {:error, :invalid_request}

  defp disable_before_archive(%{enabled: false} = config, _expected, _router, _actor, _opts),
    do: {:ok, config}

  defp disable_before_archive(config, expected, router, actor, opts) do
    case channels_call(
           router,
           :connector_prepare_disable,
           %{config: runtime_config(config)},
           actor,
           opts
         ) do
      :ok -> persist_disable(config.id, expected)
      {:error, reason} -> {:error, {:disable_failed, reason}}
      other -> {:error, {:disable_failed, {:unexpected_response, other}}}
    end
  end

  defp stop_before_archive(before, disabled, router, actor, opts) do
    case sync_runtime(before, disabled, router, actor, opts) do
      :synced -> :ok
      {:pending, reason} -> {:error, {:runtime_stop_failed, reason}}
    end
  end

  @doc "Logs out and disables exactly the connector revision confirmed by the operator."
  @spec disable(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable(request, actor, opts \\ [])

  def disable(
        %{channel_config_id: id, provider: provider, kind: kind, revision: expected},
        actor,
        opts
      )
      when is_binary(expected) do
    router = Keyword.get(opts, :router, NodeRouter)

    with {:ok, id} <- cast_id(id),
         %ChannelConfig{archived_at: nil} = before <- ChannelConfig.get(id),
         :ok <- validate_scope(before, provider, kind) do
      disable_current(before, expected, router, actor, opts)
    else
      _ -> {:error, :connector_not_found}
    end
  end

  def disable(_, _, _), do: {:error, :invalid_request}

  defp disable_current(%{enabled: false} = config, _expected, router, actor, opts) do
    {:ok,
     %{
       channel_config_id: config.id,
       status: :already_disabled,
       runtime: sync_runtime(%{config | enabled: true}, config, router, actor, opts)
     }}
  end

  defp disable_current(before, expected, router, actor, opts) do
    with :ok <- validate_revision(before, expected),
         :ok <- logout(before, router, actor, opts),
         {:ok, disabled} <- persist_disable(before.id, expected) do
      {:ok,
       %{
         channel_config_id: before.id,
         status: :disabled,
         runtime: sync_runtime(before, disabled, router, actor, opts)
       }}
    end
  end

  defp logout(config, router, actor, opts) do
    case channels_call(router, :connector_logout, %{config: runtime_config(config)}, actor, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:logout_failed, reason}}
      _ -> {:error, {:logout_failed, :unexpected_response}}
    end
  end

  # Adapter logout can write credential storage through Engine. Never hold the row
  # lock across that service call; recheck the confirmed revision before persistence.
  defp persist_disable(id, expected) do
    Repo.transaction(fn ->
      case Repo.get(ChannelConfig, id, lock: "FOR UPDATE") do
        %ChannelConfig{} = current ->
          persist_disabled_current(current, expected)

        _ ->
          Repo.rollback(:connector_not_found)
      end
    end)
  end

  defp persist_disabled_current(current, expected) do
    with :ok <- validate_revision(current, expected),
         {:ok, disabled} <- current |> Ecto.Changeset.change(enabled: false) |> Repo.update() do
      disabled
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

  defp sync_runtime(before, after_config, router, actor, opts) do
    case channels_call(
           router,
           :connector_sync_runtime,
           %{before_config: runtime_config(before), after_config: runtime_config(after_config)},
           actor,
           opts
         ) do
      :ok -> :synced
      {:ok, _} -> :synced
      {:error, reason} -> {:pending, reason}
      other -> {:pending, {:unexpected_response, other}}
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
        :data_source_runtime_module
      ])

    forwarded
    |> Keyword.put(:action, action)
    |> Keyword.put(:confidential, true)
  end
end
