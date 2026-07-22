defmodule Zaq.Engine.DataSources.WatchChannel do
  @moduledoc """
  Durable provider watch-channel runtime state for data-source webhooks.

  Engine owns this state because Channels nodes may run without database access,
  while provider watch channels require durable checkpoint and lifecycle data.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active error stopped)
  @target_kinds ~w(file collection folder)

  schema "data_source_watch_channels" do
    field :config_id, :integer
    field :provider, :string
    field :target_source, :string
    field :target_provider_id, :string
    field :target_kind, :string
    field :channel_id, :string
    field :resource_id, :string
    field :resource_uri, :string
    field :checkpoint, :string
    field :expiration_at, :utc_datetime
    field :status, :string, default: "active"
    field :last_error, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(watch_channel, attrs) when is_map(attrs) do
    watch_channel
    |> cast(attrs, [
      :config_id,
      :provider,
      :target_source,
      :target_provider_id,
      :target_kind,
      :channel_id,
      :resource_id,
      :resource_uri,
      :checkpoint,
      :expiration_at,
      :status,
      :last_error,
      :metadata
    ])
    |> normalize_string_fields([:provider, :target_kind, :status])
    |> put_default(:status, "active")
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:provider, :channel_id])
  end

  def statuses, do: @statuses

  def target_kinds, do: @target_kinds

  defp normalize_string_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      case get_change(changeset, field) do
        value when is_atom(value) -> put_change(changeset, field, to_string(value))
        "" -> delete_change(changeset, field)
        value when is_binary(value) -> put_change(changeset, field, String.trim(value))
        _ -> changeset
      end
    end)
  end

  defp put_default(changeset, field, value) do
    case get_change(changeset, field) do
      blank when blank in [nil, ""] -> force_change(changeset, field, value)
      _ -> changeset
    end
  end
end
