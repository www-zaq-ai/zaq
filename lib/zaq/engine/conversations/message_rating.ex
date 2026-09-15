defmodule Zaq.Engine.Conversations.MessageRating do
  @moduledoc "Ecto schema for a per-message rating."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_ratings" do
    field :channel_user_id, :string
    field :rating, :integer
    field :comment, :string

    belongs_to :message, Message
    belongs_to :user, Zaq.Accounts.User, type: :integer, foreign_key: :user_id
    belongs_to :person, Zaq.Accounts.Person, type: :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for creating a message rating."
  def changeset(rating, attrs) do
    rating
    |> cast(attrs, [:message_id, :user_id, :person_id, :channel_user_id, :rating, :comment])
    |> validate_required([:message_id, :rating])
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint([:message_id, :user_id])
    |> unique_constraint([:message_id, :person_id])
    |> foreign_key_constraint(:person_id)
    |> check_constraint(:person_id, name: :person_rating_actor)
    |> validate_person_actor()
  end

  defp validate_person_actor(changeset) do
    if get_field(changeset, :person_id) &&
         (get_field(changeset, :user_id) || get_field(changeset, :channel_user_id)) do
      add_error(changeset, :person_id, "cannot be combined with another author")
    else
      changeset
    end
  end
end
