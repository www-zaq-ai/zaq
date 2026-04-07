defmodule Zaq.Accounts.PersonChannel do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_platforms ~w(mattermost slack microsoft_teams whatsapp email telegram discord)

  schema "channels" do
    field :platform, :string
    field :channel_identifier, :string
    field :username, :string
    field :display_name, :string
    field :phone, :string
    field :last_interaction_at, :utc_datetime
    field :dm_channel_id, :string
    field :weight, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :person, Zaq.Accounts.Person

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :platform,
      :channel_identifier,
      :username,
      :display_name,
      :phone,
      :last_interaction_at,
      :dm_channel_id,
      :weight,
      :metadata,
      :person_id
    ])
    |> validate_required([:platform, :channel_identifier, :person_id])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:person_id)
    |> unique_constraint([:person_id, :platform, :channel_identifier])
  end

  def update_changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :platform,
      :channel_identifier,
      :username,
      :display_name,
      :phone,
      :last_interaction_at,
      :dm_channel_id,
      :weight,
      :metadata
    ])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> unique_constraint([:person_id, :platform, :channel_identifier])
  end
end
