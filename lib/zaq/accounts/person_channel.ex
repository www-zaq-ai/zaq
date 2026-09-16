defmodule Zaq.Accounts.PersonChannel do
  @moduledoc """
  Stored communication identity and channel preferences for a Person. Email
  identifiers share Person's canonical email policy; other platforms use opaque IDs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Accounts.Person

  @valid_platforms ~w(mattermost slack microsoft_teams whatsapp email telegram discord)

  @type t :: %__MODULE__{}

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
    |> normalize_channel_identifier()
    |> validate_required([:platform, :channel_identifier, :person_id])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_weight()
    |> foreign_key_constraint(:person_id)
    |> identifier_constraint()
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
    |> normalize_channel_identifier()
    |> validate_required([:platform, :channel_identifier])
    |> validate_inclusion(:platform, @valid_platforms)
    |> validate_weight()
    |> identifier_constraint()
  end

  defp identifier_constraint(changeset) do
    changeset
    |> unique_constraint([:platform, :channel_identifier],
      name: :channels_platform_channel_identifier_index,
      error_key: :channel_identifier,
      message: "This channel identifier is already assigned."
    )
  end

  @doc "Changes priority alone without normalizing identity or recording communication activity."
  @spec weight_changeset(t(), map()) :: Ecto.Changeset.t()
  def weight_changeset(channel, attrs) do
    channel
    |> cast(attrs, [:weight])
    |> validate_required([:weight])
    |> validate_weight()
  end

  defp validate_weight(changeset),
    # The persisted PostgreSQL integer is signed 32-bit; this is a storage bound,
    # not an additional product priority limit.
    do:
      validate_number(changeset, :weight,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 2_147_483_647
      )

  @doc "Canonical stored identifier for matching and merging; only email is normalized."
  @spec normalize_identifier(String.t() | nil, String.t() | nil) :: String.t() | nil
  def normalize_identifier("email", identifier), do: Person.normalize_email(identifier)

  def normalize_identifier(_platform, identifier), do: identifier

  defp normalize_channel_identifier(changeset) do
    identifier =
      normalize_identifier(
        get_field(changeset, :platform),
        get_field(changeset, :channel_identifier)
      )

    put_change(changeset, :channel_identifier, identifier)
  end
end
