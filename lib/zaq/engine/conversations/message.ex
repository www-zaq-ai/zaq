defmodule Zaq.Engine.Conversations.Message do
  @moduledoc "Ecto schema for a single message within a conversation."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{Conversation, MessageRating}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :role, :string
    field :content, :string
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer
    field :confidence_score, :float
    field :sources, {:array, :map}, default: []
    field :latency_ms, :integer
    field :metadata, :map, default: %{}

    belongs_to :conversation, Conversation
    has_many :ratings, MessageRating

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_roles ~w[user assistant]

  @doc "Changeset for inserting a new message."
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :role,
      :content,
      :model,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :confidence_score,
      :sources,
      :latency_ms,
      :metadata
    ])
    |> validate_required([:conversation_id, :role, :content])
    |> validate_inclusion(:role, @valid_roles)
  end
end
