defmodule Zaq.Engine.Conversations.MessageTraceArtifact do
  @moduledoc """
  Ecto schema for the bytes an agent read during a turn, kept so a message trace can be
  reviewed.

  The trace entry keeps a pointer to a row here plus the metadata a file chip needs — name,
  type, size — so rendering a trace never fetches bytes. `content` holds decoded bytes, not
  the base64 a provider may have transported them as, and `size` is the decoded length.

  An artifact over `max_content_bytes/0` is stored as metadata with no content: the trace
  still records what was read, without the row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_content_bytes 100 * 1024 * 1024

  schema "message_trace_artifacts" do
    field :tool_call_id, :string
    field :name, :string
    field :mime_type, :string
    field :size, :integer
    field :content, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Largest artifact kept whole. Anything bigger is stored as metadata only."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @doc """
  Changeset for inserting an artifact.

  The cap lives here rather than on the table: it is a policy about what is worth keeping, and
  moving it should not need a migration.
  """
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:tool_call_id, :name, :mime_type, :size, :content])
    |> validate_required([:tool_call_id])
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_content_size()
  end

  defp validate_content_size(changeset) do
    case get_change(changeset, :content) do
      content when is_binary(content) and byte_size(content) > @max_content_bytes ->
        add_error(changeset, :content, "exceeds the #{@max_content_bytes} byte cap")

      _within_cap_or_absent ->
        changeset
    end
  end
end
