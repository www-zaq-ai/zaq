defmodule Zaq.Engine.Conversations.MessageTraceArtifact do
  @moduledoc """
  Stores media bytes accessed during an assistant message's tool trace.

  The associated message trace contains only a safe descriptor and this row's
  identifier. Raw content is kept outside JSON trace and Record metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "message_trace_artifacts" do
    field :tool_call_id, :string
    field :tool_name, :string
    field :name, :string
    field :mime_type, :string
    field :size, :integer
    field :sha256, :binary
    field :content, :binary
    field :record, :map, default: %{}

    belongs_to :message, Message

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds an artifact changeset and enforces the configured byte limit."
  @spec changeset(t(), map(), pos_integer()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    artifact
    |> cast(attrs, [
      :tool_call_id,
      :tool_name,
      :name,
      :mime_type,
      :size,
      :sha256,
      :content,
      :record
    ])
    |> validate_required([
      :message_id,
      :tool_call_id,
      :tool_name,
      :name,
      :mime_type,
      :size,
      :sha256,
      :content
    ])
    |> validate_number(:size, greater_than_or_equal_to: 0, less_than_or_equal_to: max_bytes)
    |> validate_content(max_bytes)
  end

  defp validate_content(changeset, max_bytes) do
    content = get_field(changeset, :content)
    size = get_field(changeset, :size)
    sha256 = get_field(changeset, :sha256)

    cond do
      not is_binary(content) ->
        changeset

      byte_size(content) > max_bytes ->
        add_error(changeset, :content, "exceeds the configured size limit")

      size != byte_size(content) ->
        add_error(changeset, :size, "does not match content size")

      sha256 != :crypto.hash(:sha256, content) ->
        add_error(changeset, :sha256, "does not match content")

      true ->
        changeset
    end
  end
end
