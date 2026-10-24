defmodule ZaqWeb.Live.BO.Communication.ChannelConfigPersistence do
  @moduledoc "Persists BO connector forms; communication enabled states change through lifecycle controls."

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo

  @spec persist(
          :new | :edit,
          ChannelConfig.t() | nil,
          map(),
          String.t(),
          (Ecto.Changeset.t(), String.t() ->
             Ecto.Changeset.t()),
          keyword()
        ) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def persist(modal, existing_config, params, provider, validate_fun, opts \\ [])
      when modal in [:new, :edit] and is_map(params) and is_function(validate_fun, 2) do
    changeset =
      modal
      |> changeset(existing_config, params, opts)
      |> validate_fun.(provider)

    if modal == :new, do: Repo.insert(changeset), else: Repo.update(changeset)
  end

  @doc "Builds form validation and rejects enabled-state changes on existing communication connectors."
  def changeset(modal, existing_config, params, opts \\ []) do
    base = if modal == :new, do: %ChannelConfig{}, else: existing_config
    changeset = ChannelConfig.changeset(base, params, opts)

    if modal == :edit and existing_config.kind != "data_source" and
         Ecto.Changeset.changed?(changeset, :enabled),
       do:
         Ecto.Changeset.add_error(
           changeset,
           :enabled,
           "Use the Enable or Disable control to change connection state."
         ),
       else: changeset
  end
end
