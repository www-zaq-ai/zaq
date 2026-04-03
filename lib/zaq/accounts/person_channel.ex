defmodule Zaq.Accounts.PersonChannel do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_platforms ~w(mattermost slack microsoft_teams whatsapp email)

  schema "channels" do
    field :platform, :string
    field :channel_identifier, :string
    field :weight, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :person, Zaq.Accounts.Person

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:platform, :channel_identifier, :weight, :metadata, :person_id])
    |> validate_required([:platform, :channel_identifier, :person_id])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:person_id)
    |> unique_constraint([:person_id, :platform])
  end

  def update_changeset(channel, attrs) do
    channel
    |> cast(attrs, [:platform, :channel_identifier, :weight, :metadata])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> unique_constraint([:person_id, :platform])
  end
end
