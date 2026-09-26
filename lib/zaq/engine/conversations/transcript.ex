defmodule Zaq.Engine.Conversations.Transcript do
  @moduledoc """
  Durable strategy and scope for a message history. Threads reference their parent;
  the permission resource coordinate is stored separately from conversation ownership.
  Direct and replicated transcripts have an explicit Person owner; shared
  transcripts instead use the channel's permission resource.
  `next_position` is allocated transactionally by the Engine writer, not by callers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{Conversation, TranscriptMessage}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transcripts" do
    field :strategy, :string
    field :provider, :string
    field :channel_config_id, :integer
    field :scope_key, :string
    field :external_channel_id, :string
    field :external_thread_id, :string
    field :permission_resource_type, :string
    field :permission_resource_id, :string
    field :next_position, :integer, default: 0

    belongs_to :owner_person, Zaq.Accounts.Person, type: :integer
    belongs_to :parent, __MODULE__
    belongs_to :conversation, Conversation
    has_many :transcript_messages, TranscriptMessage

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates the persisted scope, strategy and permission coordinate."
  def changeset(transcript, attrs) do
    transcript
    |> cast(attrs, [
      :strategy,
      :provider,
      :channel_config_id,
      :scope_key,
      :external_channel_id,
      :external_thread_id,
      :parent_id,
      :conversation_id,
      :permission_resource_type,
      :permission_resource_id,
      :owner_person_id
    ])
    |> validate_required([
      :strategy,
      :provider,
      :scope_key,
      :permission_resource_type,
      :permission_resource_id
    ])
    |> validate_inclusion(:strategy, ~w(direct shared replicated))
    |> validate_owner_strategy()
    |> unique_constraint(:scope_key, name: :transcripts_scope_index)
    |> check_constraint(:owner_person_id, name: :transcripts_owner_strategy_check)
    |> foreign_key_constraint(:owner_person_id)
    |> foreign_key_constraint(:channel_config_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:conversation_id)
  end

  defp validate_owner_strategy(changeset) do
    case {get_field(changeset, :strategy), get_field(changeset, :owner_person_id)} do
      {strategy, nil} when strategy in ["direct", "replicated"] ->
        add_error(changeset, :owner_person_id, "is required for this strategy")

      {"shared", owner} when not is_nil(owner) ->
        add_error(changeset, :owner_person_id, "cannot own a shared transcript")

      _ ->
        changeset
    end
  end
end
