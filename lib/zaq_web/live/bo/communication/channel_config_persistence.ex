defmodule ZaqWeb.Live.BO.Communication.ChannelConfigPersistence do
  @moduledoc false

  alias Zaq.Engine.ChannelConfig
  alias ZaqWeb.Live.BO.EngineDispatch

  @spec persist(
          :new | :edit,
          ChannelConfig.t() | nil,
          map(),
          String.t(),
          (Ecto.Changeset.t(), String.t() -> Ecto.Changeset.t()),
          keyword()
        ) :: {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t() | term()}
  def persist(modal, existing_config, params, provider, validate_fun, opts \\ [])
      when modal in [:new, :edit] and is_map(params) and is_function(validate_fun, 2) and
             is_list(opts) do
    base = if modal == :new, do: %ChannelConfig{}, else: existing_config

    changeset =
      base
      |> ChannelConfig.changeset(params)
      |> validate_fun.(provider)

    if changeset.valid? do
      EngineDispatch.dispatch_confidential(
        :channel_config,
        %{action: :persist, modal: modal, config: base, params: params},
        Keyword.take(opts, [:actor])
      )
    else
      {:error, Map.put(changeset, :action, :validate)}
    end
  end
end
