defmodule Zaq.Engine.DataSources do
  @moduledoc """
  Engine-owned data-source runtime coordination.

  Provider watch channel state and checkpoints live here so Channels can remain
  DB-less while still acknowledging webhooks quickly after a durable handoff.

  Channels owns provider calls and webhook normalization. Engine owns durable
  watch-channel rows, checkpoint advancement, lifecycle error state, and renewal
  scheduling. Ingestion owns deciding which provider deltas become re-ingestion
  jobs or document deletions.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.WebhookUrl
  alias Zaq.Engine.DataSources.WatchChannel
  alias Zaq.Engine.DataSources.WatchChannelRenewalWorker
  alias Zaq.{Event, Repo}
  alias Zaq.Utils.Map, as: MapUtils

  @renewal_lead_seconds 3_600

  @doc """
  Creates or updates provider watch-channel runtime state.

  Attributes are normalized from atom or string keys. The resulting row stores
  provider runtime identifiers, the current checkpoint, optional expiration, and
  metadata returned by the provider. Active rows with `expiration_at` schedule a
  renewal job before provider expiry.
  """
  def upsert_watch_channel(attrs) when is_map(attrs) do
    attrs = normalize_watch_attrs(attrs)

    case get_watch_channel(attrs) do
      %WatchChannel{} = watch_channel -> update_watch_channel(watch_channel, attrs)
      nil -> create_watch_channel(attrs)
    end
  end

  @doc """
  Resolves an active, non-expired provider watch channel.

  Webhooks resolve by provider `channel_id` and optional connector `config_id`
  and `resource_id`. An unscoped legacy lookup with multiple matching connectors
  fails closed, including target-source lookups; malformed explicit connector IDs
  never fall back to an unscoped search.
  Provider watch setup and teardown can also resolve by provider, config, and
  target source. Returns `{:error, :watch_channel_not_found}` when no usable row
  exists.
  """
  def resolve_watch_channel(%{provider: provider, channel_id: channel_id} = attrs)
      when is_binary(channel_id) do
    resource_id = Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id")
    config_id = Map.get(attrs, :config_id) || Map.get(attrs, "config_id")

    with {:ok, config_id} <- valid_lookup_config_id(config_id) do
      WatchChannel
      |> where([w], w.provider == ^to_string(provider))
      |> where([w], w.channel_id == ^channel_id)
      |> maybe_filter_config_id(config_id)
      |> where([w], w.status in ["active", "error"])
      |> filter_unexpired()
      |> maybe_filter_resource_id(resource_id)
      |> limit(2)
      |> Repo.all()
      |> case do
        [watch_channel] -> {:ok, watch_channel}
        [] -> {:error, :watch_channel_not_found}
        _ -> {:error, :ambiguous_watch_channel}
      end
    end
  end

  def resolve_watch_channel(%{provider: provider, target_source: target_source} = attrs)
      when is_binary(target_source) do
    config_id = Map.get(attrs, :config_id) || Map.get(attrs, "config_id")

    with {:ok, config_id} <- valid_lookup_config_id(config_id) do
      WatchChannel
      |> where([w], w.provider == ^to_string(provider))
      |> filter_resolvable_watch_channel(target_source, changes_watch_lookup?(attrs))
      |> filter_unexpired()
      |> maybe_filter_config_id(config_id)
      |> select_target_watch(config_id)
    end
  end

  def resolve_watch_channel(_attrs), do: {:error, :missing_channel_id}

  defp select_target_watch(query, nil) do
    case query |> select([w], w.config_id) |> distinct(true) |> limit(2) |> Repo.all() do
      [_config_id] -> newest_target_watch(query)
      [] -> {:error, :watch_channel_not_found}
      _ -> {:error, :ambiguous_watch_channel}
    end
  end

  defp select_target_watch(query, _config_id), do: newest_target_watch(query)

  defp newest_target_watch(query) do
    query
    |> order_by([w], desc: w.updated_at, desc: w.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      %WatchChannel{} = watch_channel -> {:ok, watch_channel}
      nil -> {:error, :watch_channel_not_found}
    end
  end

  defp valid_lookup_config_id(nil), do: {:ok, nil}
  defp valid_lookup_config_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp valid_lookup_config_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_connector_id}
    end
  end

  defp valid_lookup_config_id(_id), do: {:error, :invalid_connector_id}

  defp filter_resolvable_watch_channel(query, target_source, true) do
    where(
      query,
      [w],
      (w.target_source == ^target_source or
         (w.target_provider_id == "changes" and w.target_kind == "collection")) and
        w.status in ["active", "error"]
    )
  end

  defp filter_resolvable_watch_channel(query, target_source, false) do
    where(query, [w], w.target_source == ^target_source and w.status in ["active", "error"])
  end

  defp changes_watch_lookup?(attrs) do
    (Map.get(attrs, :target_provider_id) || Map.get(attrs, "target_provider_id")) == "changes"
  end

  defp filter_unexpired(query) do
    now = DateTime.utc_now()
    where(query, [w], is_nil(w.expiration_at) or w.expiration_at > ^now)
  end

  @doc """
  Processes metadata-only provider watch changes and advances checkpoint on success.

  The request must include `watch_channel_id` and may include `signals`,
  `records`, `delivery`, `checkpoint`, and `next_checkpoint`. Engine validates
  that the caller processed the stored checkpoint, dispatches to Ingestion, then
  persists the next checkpoint only after Ingestion succeeds.
  """
  def process_watch_changes(%{watch_channel_id: id} = request) do
    with %WatchChannel{} = watch_channel <-
           Repo.get(WatchChannel, id) || {:error, :watch_channel_not_found},
         :ok <- maybe_validate_checkpoint(watch_channel, request),
         {:ok, result} <- dispatch_ingestion_changes(watch_channel, request),
         {:ok, _watch_channel} <- maybe_update_checkpoint(watch_channel, request) do
      {:ok, result}
    else
      {:error, reason} = error ->
        _ = mark_watch_channel_error(id, reason)
        error
    end
  end

  def process_watch_changes(_request), do: {:error, :missing_watch_channel_id}

  @doc "Marks a watch channel stopped after provider teardown succeeds."
  def mark_watch_channel_stopped(id) do
    with %WatchChannel{} = watch_channel <-
           Repo.get(WatchChannel, id) || {:error, :watch_channel_not_found} do
      update_watch_channel(watch_channel, %{status: "stopped", last_error: nil})
    end
  end

  @doc "Stops each live provider watch before archiving its connector; successful stops are durable."
  @spec stop_config_watch_channels(pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, [{integer(), term()}]}
  def stop_config_watch_channels(config_id) when is_integer(config_id) and config_id > 0 do
    watches =
      Repo.all(
        from w in WatchChannel,
          where: w.config_id == ^config_id and w.status in ["active", "error"],
          order_by: w.id
      )

    results =
      Enum.map(watches, fn watch ->
        case stop_provider_watch_channel(watch) do
          :ok -> {watch.id, mark_watch_channel_stopped(watch.id)}
          {:error, reason} -> {watch.id, {:error, reason}}
        end
      end)

    failures = for {id, {:error, reason}} <- results, do: {id, reason}
    if failures == [], do: {:ok, length(watches)}, else: {:error, failures}
  end

  def stop_config_watch_channels(_), do: {:error, [{nil, :invalid_connector_id}]}

  @doc "Enqueues cleanup for watches that raced with connector archive."
  @spec reconcile_archived_config_watches(pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_archived_config_watches(config_id) when is_integer(config_id) and config_id > 0 do
    if archived_connector?(config_id) do
      WatchChannel
      |> where([w], w.config_id == ^config_id and w.status in ["active", "error"])
      |> Repo.all()
      |> Enum.reduce_while({:ok, 0}, &enqueue_archived_watch_cleanup/2)
    else
      {:error, :connector_not_archived}
    end
  end

  def reconcile_archived_config_watches(_), do: {:error, :invalid_connector_id}

  defp enqueue_archived_watch_cleanup(watch, {:ok, count}) do
    case schedule_watch_channel_renewal(watch) do
      {:ok, _job} -> {:cont, {:ok, count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc "Marks a watch channel errored and stores an inspectable failure reason."
  def mark_watch_channel_error(id, reason) do
    case Repo.get(WatchChannel, id) do
      %WatchChannel{} = watch_channel ->
        update_watch_channel(watch_channel, %{status: "error", last_error: inspect(reason)})

      nil ->
        {:error, :watch_channel_not_found}
    end
  end

  defp get_watch_channel(attrs) do
    provider = Map.get(attrs, :provider)
    channel_id = Map.get(attrs, :channel_id)
    config_id = Map.get(attrs, :config_id)

    if is_binary(provider) and is_binary(channel_id) and is_integer(config_id) and config_id > 0 do
      Repo.get_by(WatchChannel,
        provider: provider,
        channel_id: channel_id,
        config_id: config_id
      )
    end
  end

  defp create_watch_channel(attrs) do
    %WatchChannel{}
    |> WatchChannel.changeset(attrs)
    |> Repo.insert()
    |> maybe_schedule_watch_channel_renewal()
  end

  defp update_watch_channel(%WatchChannel{} = watch_channel, attrs) do
    watch_channel
    |> Changeset.change(compact_attrs(attrs))
    |> Repo.update()
    |> maybe_schedule_watch_channel_renewal()
  end

  @doc """
  Renews an expiring watch channel.

  Renewal recomputes the public webhook URL from global system config, creates a
  replacement provider channel first, stops the old provider channel, and deletes
  the old row. Missing or already-stopped rows are treated as no-ops by the Oban
  worker.
  """
  def renew_watch_channel(id) do
    with %WatchChannel{} = old_watch_channel <-
           Repo.get(WatchChannel, id) || {:error, :watch_channel_not_found} do
      if archived_connector?(old_watch_channel.config_id) do
        cleanup_archived_watch_channel(old_watch_channel)
      else
        renew_active_watch_channel(old_watch_channel)
      end
    end
  end

  defp renew_active_watch_channel(old_watch_channel) do
    with true <- old_watch_channel.status == "active" || :ok,
         {:ok, new_watch_channel} <- create_replacement_watch_channel(old_watch_channel),
         :ok <- stop_provider_watch_channel(old_watch_channel),
         {:ok, _deleted} <- Repo.delete(old_watch_channel) do
      {:ok, new_watch_channel}
    else
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_archived_watch_channel(%WatchChannel{status: status} = watch_channel)
       when status in ["active", "error"] do
    case stop_provider_watch_channel(watch_channel) do
      :ok ->
        case mark_watch_channel_stopped(watch_channel.id) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, reason} = error ->
        _ = mark_watch_channel_error(watch_channel.id, reason)
        error
    end
  end

  defp cleanup_archived_watch_channel(_watch_channel), do: :ok

  defp archived_connector?(config_id) do
    match?(%ChannelConfig{archived_at: %DateTime{}}, Repo.get(ChannelConfig, config_id))
  end

  defp maybe_schedule_watch_channel_renewal({:ok, %WatchChannel{} = watch_channel} = result) do
    case schedule_watch_channel_renewal(watch_channel) do
      {:error, reason} when watch_channel.status in ["active", "error"] ->
        if archived_connector?(watch_channel.config_id) do
          _ =
            watch_channel
            |> Changeset.change(
              status: "error",
              last_error: inspect({:cleanup_enqueue_failed, reason})
            )
            |> Repo.update()

          {:error, {:cleanup_enqueue_failed, reason}}
        else
          result
        end

      _ ->
        result
    end
  end

  defp maybe_schedule_watch_channel_renewal(result), do: result

  defp schedule_watch_channel_renewal(%WatchChannel{status: status} = watch_channel)
       when status in ["active", "error"] do
    cond do
      archived_connector?(watch_channel.config_id) ->
        %{watch_channel_id: watch_channel.id}
        |> WatchChannelRenewalWorker.new(
          unique: [
            keys: [:watch_channel_id],
            states: [:scheduled, :available, :retryable],
            period: :infinity
          ],
          replace: [scheduled: [:scheduled_at]]
        )
        |> Oban.insert()

      status == "active" ->
        schedule_active_watch_channel_renewal(watch_channel)

      true ->
        :ok
    end
  end

  defp schedule_watch_channel_renewal(%WatchChannel{}), do: :ok

  defp schedule_active_watch_channel_renewal(%WatchChannel{
         expiration_at: %DateTime{} = expiration_at,
         id: id
       }) do
    scheduled_at =
      expiration_at
      |> DateTime.add(-@renewal_lead_seconds, :second)
      |> max_datetime(DateTime.utc_now())

    %{watch_channel_id: id}
    |> WatchChannelRenewalWorker.new(
      scheduled_at: scheduled_at,
      unique: [
        keys: [:watch_channel_id],
        states: [:scheduled, :available, :retryable],
        period: :infinity
      ],
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  defp schedule_active_watch_channel_renewal(_watch_channel), do: :ok

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp create_replacement_watch_channel(%WatchChannel{} = watch_channel) do
    case WebhookUrl.build(:data_source, watch_channel.provider, watch_channel.config_id) do
      webhook_url when is_binary(webhook_url) ->
        do_create_replacement_watch_channel(watch_channel, webhook_url)

      _ ->
        {:error, :missing_global_base_url}
    end
  end

  defp do_create_replacement_watch_channel(%WatchChannel{} = watch_channel, webhook_url) do
    params = %{
      config_id: watch_channel.config_id,
      target_source: watch_channel.target_source,
      target_provider_id: watch_channel.target_provider_id,
      kind: watch_channel.target_kind,
      checkpoint: watch_channel.checkpoint,
      webhook_url: webhook_url,
      force_new_watch_channel: true
    }

    event =
      Event.new(%{provider: watch_channel.provider, params: params}, :channels,
        opts: [action: :data_source_watch_item]
      )

    case node_router_module().dispatch(event).response do
      {:ok, %{channel_id: channel_id}} when is_binary(channel_id) ->
        case Repo.get_by(WatchChannel,
               provider: watch_channel.provider,
               channel_id: channel_id,
               config_id: watch_channel.config_id
             ) do
          %WatchChannel{} = new_watch_channel -> {:ok, new_watch_channel}
          nil -> {:error, :replacement_watch_channel_not_persisted}
        end

      {:ok, _payload} ->
        {:error, :replacement_watch_channel_missing_channel_id}

      {:error, _reason} = error ->
        error

      other ->
        {:error, other}
    end
  end

  defp stop_provider_watch_channel(%WatchChannel{} = watch_channel) do
    params = %{
      config_id: watch_channel.config_id,
      channel_id: watch_channel.channel_id,
      resource_id: watch_channel.resource_id
    }

    action =
      if archived_connector?(watch_channel.config_id),
        do: :data_source_unwatch_archived_item,
        else: :data_source_unwatch_item

    event =
      Event.new(%{provider: watch_channel.provider, params: params}, :channels,
        opts: [action: action]
      )

    case node_router_module().dispatch(event).response do
      :ok -> :ok
      {:ok, _payload} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp maybe_filter_resource_id(query, resource_id)
       when is_binary(resource_id) and resource_id != "" do
    where(query, [w], is_nil(w.resource_id) or w.resource_id == ^resource_id)
  end

  defp maybe_filter_resource_id(query, _resource_id), do: query

  defp maybe_filter_config_id(query, config_id) when is_integer(config_id) do
    where(query, [w], w.config_id == ^config_id)
  end

  defp maybe_filter_config_id(query, nil), do: query

  defp maybe_validate_checkpoint(%WatchChannel{checkpoint: checkpoint}, request) do
    current = Map.get(request, :checkpoint) || Map.get(request, "checkpoint")

    if is_nil(current) or current == checkpoint do
      :ok
    else
      {:error, :stale_checkpoint}
    end
  end

  defp dispatch_ingestion_changes(%WatchChannel{} = watch_channel, request) do
    event =
      Event.new(
        ingestion_changes_request(watch_channel, request),
        :ingestion,
        opts: [action: :process_data_source_changes]
      )

    event |> node_router_module().dispatch() |> normalize_ingestion_response()
  end

  defp ingestion_changes_request(%WatchChannel{} = watch_channel, request) do
    %{
      watch_channel: watch_channel,
      provider: watch_channel.provider,
      config_id: watch_channel.config_id,
      target_source: watch_channel.target_source,
      target_provider_id: watch_channel.target_provider_id,
      target_kind: watch_channel.target_kind,
      signals: Map.get(request, :signals) || Map.get(request, "signals") || [],
      records: Map.get(request, :records) || Map.get(request, "records") || [],
      delivery: Map.get(request, :delivery) || Map.get(request, "delivery") || %{},
      trigger_id: Map.get(request, :trigger_id) || Map.get(request, "trigger_id")
    }
  end

  defp normalize_ingestion_response(%Event{response: {:ok, _result} = ok}), do: ok
  defp normalize_ingestion_response(%Event{response: :ok}), do: {:ok, :ok}
  defp normalize_ingestion_response(%Event{response: {:error, reason}}), do: {:error, reason}
  defp normalize_ingestion_response(%Event{response: other}), do: {:error, other}

  defp maybe_update_checkpoint(%WatchChannel{} = watch_channel, request) do
    case Map.get(request, :next_checkpoint) || Map.get(request, "next_checkpoint") do
      checkpoint when is_binary(checkpoint) and checkpoint != "" ->
        update_watch_channel(watch_channel, %{
          checkpoint: checkpoint,
          status: "active",
          last_error: nil,
          metadata: put_watch_metadata(watch_channel.metadata, %{checkpoint: checkpoint})
        })

      _ ->
        {:ok, watch_channel}
    end
  end

  defp normalize_watch_attrs(attrs) do
    attrs = %{
      config_id: attrs |> read_any([:config_id, "config_id"]) |> normalize_config_id(),
      provider: read_string(attrs, [:provider, "provider"]),
      target_source: read_string(attrs, [:target_source, "target_source", :source, "source"]),
      target_provider_id:
        read_string(attrs, [:target_provider_id, "target_provider_id", :file_id, "file_id"]),
      target_kind: read_string(attrs, [:target_kind, "target_kind", :kind, "kind"]),
      channel_id: read_string(attrs, [:channel_id, "channel_id"]),
      resource_id: read_string(attrs, [:resource_id, "resource_id"]),
      resource_uri: read_string(attrs, [:resource_uri, "resource_uri"]),
      checkpoint: read_string(attrs, [:checkpoint, "checkpoint"]),
      expiration_at: read_expiration_at(attrs),
      status: read_string(attrs, [:status, "status"]) || "active",
      last_error: read_string(attrs, [:last_error, "last_error"]),
      metadata: read_any(attrs, [:metadata, "metadata"]) || %{}
    }

    attrs = Map.update(attrs, :metadata, %{}, &put_watch_metadata(&1, attrs))

    attrs
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp read_string(map, keys) do
    MapUtils.read_stringish(map, keys)
  end

  defp read_any(map, keys), do: MapUtils.read_any(map, keys)

  defp normalize_config_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed_id, ""} -> parsed_id
      _ -> id
    end
  end

  defp normalize_config_id(id), do: id

  defp read_expiration_at(attrs) do
    direct = read_any(attrs, [:expiration_at, "expiration_at"])
    expiration = read_any(attrs, [:expiration, "expiration"])

    parse_expiration_at(direct) || parse_expiration_at(expiration)
  end

  defp parse_expiration_at(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)

  defp parse_expiration_at(value) when is_integer(value), do: expiration_from_unix(value)

  defp parse_expiration_at(value) when is_binary(value) do
    if Regex.match?(~r/^\d+$/, value) do
      value |> String.to_integer() |> expiration_from_unix()
    else
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
        _ -> nil
      end
    end
  end

  defp parse_expiration_at(_value), do: nil

  defp expiration_from_unix(value) when is_integer(value) and value > 9_999_999_999 do
    value |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
  end

  defp expiration_from_unix(value) when is_integer(value) do
    value |> DateTime.from_unix!() |> DateTime.truncate(:second)
  end

  defp put_watch_metadata(metadata, attrs) when is_map(metadata) and is_map(attrs) do
    watch = read_any(metadata, [:watch, "watch"]) || %{}

    watch_updates =
      %{
        "provider" => watch_metadata_value(Map.get(attrs, :provider)),
        "channel_id" => watch_metadata_value(Map.get(attrs, :channel_id)),
        "resource_id" => watch_metadata_value(Map.get(attrs, :resource_id)),
        "resource_uri" => watch_metadata_value(Map.get(attrs, :resource_uri)),
        "file_id" => watch_metadata_value(Map.get(attrs, :target_provider_id)),
        "collection_id" => watch_metadata_value(Map.get(attrs, :target_provider_id)),
        "kind" => watch_metadata_value(Map.get(attrs, :target_kind)),
        "checkpoint" => watch_metadata_value(Map.get(attrs, :checkpoint)),
        "expiration_at" => format_datetime(Map.get(attrs, :expiration_at))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    Map.put(metadata, "watch", Map.merge(stringify_keys(watch), watch_updates))
  end

  defp put_watch_metadata(_metadata, _attrs), do: %{}

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_map), do: %{}

  defp watch_metadata_value(nil), do: nil
  defp watch_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp watch_metadata_value(value) when is_binary(value), do: value
  defp watch_metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  defp watch_metadata_value(_value), do: nil

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: nil

  defp node_router_module do
    Application.get_env(:zaq, :engine_data_sources_node_router_module, Zaq.NodeRouter)
  end
end
