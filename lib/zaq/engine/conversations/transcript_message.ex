defmodule Zaq.Engine.Conversations.TranscriptMessage do
  @moduledoc """
  One canonical message's placement in a transcript. Position is local to the
  transcript and allocated under a row lock by the Engine persistence context.
  Reattachment of an old message gets a new position, not its provider timestamp.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{Message, Transcript}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transcript_messages" do
    field :position, :integer
    field :provenance, :string

    belongs_to :message, Message
    belongs_to :transcript, Transcript

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Validates the association and its committed transcript-local position."
  def changeset(association, attrs) do
    association
    |> cast(attrs, [:message_id, :transcript_id, :position, :provenance])
    |> validate_required([:message_id, :transcript_id, :position, :provenance])
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint(:message_id, name: :transcript_messages_message_index)
    |> unique_constraint(:position, name: :transcript_messages_position_index)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:transcript_id)
  end
end
