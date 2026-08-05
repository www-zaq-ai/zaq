defmodule ZaqWeb.Live.BO.Communication.ChannelConfigPersistence do
  @moduledoc false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  @spec persist(:new | :edit, ChannelConfig.t() | nil, map(), String.t(), (Ecto.Changeset.t(),
                                                                           String.t() ->
                                                                             Ecto.Changeset.t())) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def persist(modal, existing_config, params, provider, validate_fun)
      when modal in [:new, :edit] and is_map(params) and is_function(validate_fun, 2) do
    base = if modal == :new, do: %ChannelConfig{}, else: existing_config

    changeset =
      base
      |> ChannelConfig.changeset(merge_settings(base, params))
      |> validate_fun.(provider)

    if modal == :new, do: Repo.insert(changeset), else: Repo.update(changeset)
  end

  # `settings` is cast whole, but a form only renders the subtrees it knows about — the
  # channel form posts `attachments`, the data-source form posts `connect`. Casting the
  # posted map directly would drop every key the open form happens not to render, so the
  # submitted subtrees are merged over what is already stored.
  defp merge_settings(base, params) do
    case settings_param(params) do
      nil -> params
      posted -> put_settings(params, deep_merge(stored_settings(base), posted))
    end
  end

  defp settings_param(params), do: Map.get(params, "settings") || Map.get(params, :settings)

  defp put_settings(params, settings) do
    if Map.has_key?(params, "settings"),
      do: Map.put(params, "settings", settings),
      else: Map.put(params, :settings, settings)
  end

  defp stored_settings(%ChannelConfig{settings: settings}) when is_map(settings), do: settings
  defp stored_settings(_base), do: %{}

  defp deep_merge(stored, posted) when is_map(stored) and is_map(posted) do
    Map.merge(stored, posted, fn _key, stored_value, posted_value ->
      deep_merge(stored_value, posted_value)
    end)
  end

  defp deep_merge(_stored, posted), do: posted
end
