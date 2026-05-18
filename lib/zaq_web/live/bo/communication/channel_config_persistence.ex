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
      |> ChannelConfig.changeset(params)
      |> validate_fun.(provider)

    if modal == :new, do: Repo.insert(changeset), else: Repo.update(changeset)
  end
end
