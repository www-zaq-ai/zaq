defmodule Zaq.Engine.LiveUpdateSettings do
  @moduledoc """
  Engine-owned management and runtime projection of streamed-update policies.

  The BO Action authenticates management callers. Saves lock the exact connector
  and merge only the policy subtree; snapshots never contain connector secrets.
  Saves optionally fence an enclosing editor's expected lifecycle revision and
  return the exact previous/new revision pair so it can retain unsaved fields.
  Grouped connector edits validate ordinary fields and policy inside one transaction;
  widgets compose policy saves inside their existing configuration transaction.
  Runtime resolution is a read-only projection of trusted incoming routing, not
  an authorization grant. Status updates are outside this policy.
  """

  import Ecto.Query

  alias Zaq.ConnectorConfig.LiveUpdates
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  @doc "Reads or saves one persisted connector policy for the authenticated BO Action."
  def execute(%{op: :snapshot, id: id}) do
    with {:ok, config} <- selected(id), do: snapshot(config)
  end

  def execute(%{op: :save, id: id, policy: policy} = request) do
    with {:ok, policy} <- normalize_form(policy),
         {:ok, id} <- connector_id(id) do
      Repo.transact(fn -> save_locked(id, policy, Map.get(request, :revision)) end)
    end
  end

  def execute(%{
        op: :save_configuration,
        id: id,
        revision: revision,
        params: params,
        policy: policy
      })
      when is_map(params) and is_binary(revision) do
    with {:ok, policy} <- normalize_form(policy),
         {:ok, id} <- connector_id(id) do
      Repo.transact(fn -> save_configuration_locked(id, revision, params, policy) end)
    end
  end

  def execute(_request), do: {:error, :invalid_request}

  defp save_locked(id, policy, expected_revision) do
    with {:ok, config} <- selected(id, lock: true),
         {:ok, previous} <- ConnectorLifecycle.context(id, config.provider, config.kind),
         :ok <- validate_revision(expected_revision, previous.revision),
         {:ok, saved} <- persist(config, policy),
         {:ok, current} <- ConnectorLifecycle.context(id, saved.provider, saved.kind),
         {:ok, result} <- snapshot(saved) do
      {:ok,
       Map.merge(result, %{previous_revision: previous.revision, revision: current.revision})}
    end
  end

  defp validate_revision(nil, _current), do: :ok
  defp validate_revision(revision, revision), do: :ok
  defp validate_revision(_expected, _current), do: {:error, :stale_connector}

  defp save_configuration_locked(id, revision, params, policy) do
    with {:ok, config} <- selected(id, lock: true),
         :ok <- generic_connector(config),
         {:ok, descriptor} <- ConnectorLifecycle.context(id, config.provider, config.kind),
         :ok <- validate_revision(revision, descriptor.revision),
         {:ok, saved} <- update_configuration(config, params) do
      if LiveUpdates.from_settings(config.settings) == {:ok, policy},
        do: snapshot(saved),
        else: save_locked(id, policy, nil)
    end
  end

  defp generic_connector(%{provider: "web_widget"}), do: {:error, :invalid_request}
  defp generic_connector(_config), do: :ok

  defp update_configuration(config, params) do
    attrs = Map.take(params, ~w(name url token enabled settings))

    case config |> ChannelConfig.changeset(attrs) |> Repo.update() do
      {:ok, saved} ->
        {:ok, saved}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)
        {:error, {:configuration, errors}}
    end
  end

  @doc "Projects only the policy for already-admitted trusted incoming routing."
  def resolve(%Incoming{provider: provider, routing_context: context}) do
    case context do
      %{channel_config_id: id} when not is_nil(id) ->
        with {:ok, config} <- selected(id),
             true <- config.provider == to_string(provider) do
          normalized(config.settings)
        else
          _ -> {:error, :connector_not_found}
        end

      _ when provider in [:web, "web"] ->
        {:ok, LiveUpdates.defaults()}

      _ ->
        {:error, :connector_not_found}
    end
  end

  def resolve(_incoming), do: {:error, :invalid_request}

  defp selected(id, opts \\ []) do
    with {:ok, id} <- connector_id(id) do
      query =
        from(config in ChannelConfig,
          where: config.id == ^id and config.kind == "retrieval" and is_nil(config.archived_at)
        )

      query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query

      case Repo.one(query) do
        nil -> {:error, :connector_not_found}
        config -> {:ok, config}
      end
    end
  end

  defp connector_id(value) do
    case ParseUtils.parse_int_strict(value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> {:error, :connector_not_found}
    end
  end

  defp persist(config, policy) do
    config
    |> Ecto.Changeset.change(settings: Map.put(config.settings, "live_updates", policy))
    |> Repo.update()
  end

  defp snapshot(config) do
    with {:ok, policy} <- normalized(config.settings),
         {:ok, descriptor} <- ConnectorLifecycle.context(config.id, config.provider, config.kind),
         do: {:ok, %{id: config.id, policy: policy, revision: descriptor.revision}}
  end

  defp normalized(settings) do
    case LiveUpdates.from_settings(settings) do
      {:ok, policy} -> {:ok, policy}
      {:error, errors} -> {:error, {:validation, errors}}
    end
  end

  defp normalize_form(policy) do
    case LiveUpdates.normalize_form(policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, errors} -> {:error, {:validation, errors}}
    end
  end
end
