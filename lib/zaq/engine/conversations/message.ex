defmodule Zaq.Engine.Conversations.Message do
  @moduledoc """
  A message with stable identity. Legacy messages belong to one conversation;
  canonical channel messages may belong to several transcripts instead.
  Execution metadata and private traces must not be projected as shared history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.{
    Conversation,
    MessageRating,
    MessageTraceArtifact,
    TranscriptMessage
  }

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
    field :source_provider, :string
    field :source_account_key, :string
    field :external_message_id, :string
    field :author_id, :string
    field :author_name, :string
    field :provider_sent_at, :utc_datetime_usec
    field :attachments, {:array, :map}, default: []

    belongs_to :conversation, Conversation
    has_many :ratings, MessageRating
    has_many :trace_artifacts, MessageTraceArtifact
    has_many :transcript_messages, TranscriptMessage

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
    |> validate_content_or_attachments(["user"])
    |> unique_constraint(:metadata, name: :messages_admitted_external_id_index)
  end

  @doc "Changeset for canonical content, without a single-conversation ownership requirement."
  def canonical_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :role,
      :content,
      :source_provider,
      :source_account_key,
      :external_message_id,
      :author_id,
      :author_name,
      :provider_sent_at,
      :attachments
    ])
    |> validate_required([:role])
    |> validate_inclusion(:role, @valid_roles ++ ["external"])
    |> validate_content_or_attachments(@valid_roles ++ ["external"])
    |> validate_source_identity()
    |> validate_immutable_source_identity()
    |> check_constraint(:external_message_id, name: :messages_source_identity_check)
    |> unique_constraint(:external_message_id, name: :messages_canonical_source_index)
  end

  defp validate_source_identity(changeset) do
    fields = [:source_provider, :source_account_key, :external_message_id]

    if Enum.any?(fields, &get_field(changeset, &1)) do
      Enum.reduce(fields, changeset, fn field, current ->
        validate_required(current, [field])
      end)
    else
      changeset
    end
  end

  defp validate_immutable_source_identity(%{data: %{external_message_id: nil}} = changeset),
    do: changeset

  defp validate_immutable_source_identity(changeset) do
    Enum.reduce(
      [:source_provider, :source_account_key, :external_message_id],
      changeset,
      fn field, current ->
        reject_source_change(current, field)
      end
    )
  end

  defp reject_source_change(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, _value} -> add_error(changeset, field, "cannot change a persisted source identity")
      :error -> changeset
    end
  end

  defp validate_content_or_attachments(changeset, attachment_only_roles) do
    role = get_field(changeset, :role)
    content = get_field(changeset, :content)
    metadata = get_field(changeset, :metadata) || %{}
    legacy_attachments = Map.get(metadata, "attachments") || Map.get(metadata, :attachments)

    attachments =
      attachment_list(get_field(changeset, :attachments)) ++ attachment_list(legacy_attachments)

    case {content_present?(content), role in attachment_only_roles and attachments != []} do
      {true, _} ->
        changeset

      {false, true} ->
        put_change(changeset, :content, content || "")

      {false, false} ->
        add_error(changeset, :content, "can't be blank")
    end
  end

  defp attachment_list(value) when is_list(value), do: value
  defp attachment_list(_value), do: []

  defp content_present?(content), do: is_binary(content) and String.trim(content) != ""
end
