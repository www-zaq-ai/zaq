defmodule Zaq.Engine.Conversations.Message do
  @moduledoc "Ecto schema for a single message within a conversation."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{Conversation, MessageRating, MessageTraceArtifact}

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
    field :trace, {:array, :map}, default: []

    belongs_to :conversation, Conversation
    has_many :ratings, MessageRating
    has_many :trace_artifacts, MessageTraceArtifact

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
      :metadata,
      :trace
    ])
    |> validate_required([:conversation_id, :role])
    |> validate_inclusion(:role, @valid_roles)
    |> validate_content_or_attachments()
  end

  defp validate_content_or_attachments(changeset) do
    role = get_field(changeset, :role)
    content = get_field(changeset, :content)
    metadata = get_field(changeset, :metadata) || %{}
    attachments = Map.get(metadata, "attachments") || Map.get(metadata, :attachments) || []

    case {content_present?(content), user_attachments?(role, attachments)} do
      {true, _} ->
        changeset

      {false, true} ->
        put_change(changeset, :content, content || "")

      {false, false} ->
        add_error(changeset, :content, "can't be blank")
    end
  end

  defp content_present?(content), do: is_binary(content) and String.trim(content) != ""

  defp user_attachments?("user", attachments), do: is_list(attachments) and attachments != []
  defp user_attachments?(_role, _attachments), do: false
end
