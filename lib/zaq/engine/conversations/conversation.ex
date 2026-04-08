defmodule Zaq.Engine.Conversations.Conversation do
  @moduledoc "Ecto schema for a conversation between a user and the ZAQ agent."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{ConversationShare, Message}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :title, :string
    field :channel_user_id, :string
    field :channel_type, :string
    field :channel_config_id, :integer
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :user, Zaq.Accounts.User, type: :integer, foreign_key: :user_id
    has_many :messages, Message
    has_many :shares, ConversationShare

    timestamps(type: :utc_datetime_usec)
  end

  @valid_channel_types ~w[mattermost discord slack bo api email:imap]
  @valid_statuses ~w[active archived]

  @doc "Changeset for creating or updating a conversation."
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :title,
      :user_id,
      :channel_user_id,
      :channel_type,
      :channel_config_id,
      :status,
      :metadata
    ])
    |> validate_required([:channel_type])
    |> validate_inclusion(:channel_type, @valid_channel_types)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
