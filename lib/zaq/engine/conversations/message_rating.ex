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

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for creating a message rating."
  def changeset(rating, attrs) do
    rating
    |> cast(attrs, [:message_id, :user_id, :channel_user_id, :rating, :comment])
    |> validate_required([:message_id, :rating])
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint([:message_id, :user_id])
  end
end
