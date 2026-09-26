defmodule Zaq.Engine.Conversations.ExecutionRecord do
  @moduledoc """
  Private, Person-bound execution state distinct from shareable canonical content.

  The user and public answer are referenced by their stable Message UUIDs. Only
  the capability hash is persisted, never the raw finalization token. Private
  trace entries, tool results, usage and outcome must never enter a transcript
  projection. Existing legacy Message metadata/trace is migrated separately.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "execution_records" do
    field :status, :string, default: "pending"
    field :finalization_token_hash, :string
    field :trace_entries, {:array, :map}, default: []
    field :tool_results, {:array, :map}, default: []
    field :usage, :map, default: %{}
    field :outcome, :map, default: %{}

    belongs_to :person, Zaq.Accounts.Person, type: :integer
    belongs_to :user_message, Message
    belongs_to :public_answer_message, Message

    timestamps(type: :utc_datetime_usec)
  end

  @statuses ~w(pending completed failed)
  @hash_pattern ~r/\A[A-Za-z0-9+\/]{43}=\z/

  @doc "Validates private execution ownership, capability hash, and public-answer linkage."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :person_id,
      :user_message_id,
      :public_answer_message_id,
      :status,
      :finalization_token_hash,
      :trace_entries,
      :tool_results,
      :usage,
      :outcome
    ])
    |> validate_required([:person_id, :user_message_id, :status, :finalization_token_hash])
    |> validate_number(:person_id, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:finalization_token_hash, @hash_pattern)
    |> validate_answer_status()
    |> unique_constraint(:public_answer_message_id, name: :execution_records_public_answer_index)
    |> unique_constraint(:finalization_token_hash)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:user_message_id)
    |> foreign_key_constraint(:public_answer_message_id)
    |> check_constraint(:status, name: :execution_records_status_check)
    |> check_constraint(:public_answer_message_id, name: :execution_records_answer_status_check)
    |> check_constraint(:public_answer_message_id, name: :execution_records_distinct_answer_check)
    |> check_constraint(:finalization_token_hash, name: :execution_records_capability_hash_check)
  end

  defp validate_answer_status(changeset) do
    user_message_id = get_field(changeset, :user_message_id)

    case {get_field(changeset, :status), get_field(changeset, :public_answer_message_id)} do
      {"completed", nil} ->
        add_error(changeset, :public_answer_message_id, "is required for completed execution")

      {status, id} when status in ["pending", "failed"] and not is_nil(id) ->
        add_error(changeset, :public_answer_message_id, "requires completed execution")

      {_status, ^user_message_id} when not is_nil(user_message_id) ->
        add_error(changeset, :public_answer_message_id, "must differ from the input message")

      _ ->
        changeset
    end
  end
end
