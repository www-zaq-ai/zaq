defmodule Zaq.Engine.Conversations.ExecutionRecord do
  @moduledoc """
  Private, Person-bound execution state distinct from shareable canonical content.

  The user and public answer are referenced by their stable Message UUIDs. Only
  the capability hash is persisted, never the raw finalization token. Private
  trace entries, tool results, usage and outcome must never enter a transcript
  projection. Existing legacy Message metadata/trace is migrated separately.

  `reserved_answer_message_id` is an Engine-owned root reservation, not a Message
  foreign key. It can exist before any answer and survives unsuccessful execution.
  A receipt cannot own a reservation; a persisted public answer must match it.
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
    field :admitted_at, :utc_datetime_usec
    field :reserved_answer_message_id, Ecto.UUID
    field :trace_entries, {:array, :map}, default: []
    field :tool_results, {:array, :map}, default: []
    field :usage, :map, default: %{}
    field :outcome, :map, default: %{}

    belongs_to :person, Zaq.Accounts.Person, type: :integer
    belongs_to :user_message, Message
    belongs_to :public_answer_message, Message
    belongs_to :root_execution, __MODULE__
    belongs_to :recovered_from_execution, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @root_statuses ~w(pending completed failed)
  @receipt_statuses ~w(queued consumed unconsumed)
  @statuses @root_statuses ++ @receipt_statuses
  @hash_pattern ~r/\A[A-Za-z0-9+\/]{43}=\z/

  @doc "Validates private execution ownership, capability hash, and public-answer linkage."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :person_id,
      :user_message_id,
      :public_answer_message_id,
      :root_execution_id,
      :recovered_from_execution_id,
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
    |> validate_root_status()
    |> validate_answer_reservation()
    |> validate_immutable_identity()
    |> unique_constraint(:public_answer_message_id, name: :execution_records_public_answer_index)
    |> unique_constraint(:finalization_token_hash)
    |> unique_constraint(:recovered_from_execution_id)
    |> unique_constraint(:user_message_id, name: :execution_records_input_root_index)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:user_message_id)
    |> foreign_key_constraint(:public_answer_message_id)
    |> foreign_key_constraint(:root_execution_id)
    |> foreign_key_constraint(:recovered_from_execution_id)
    |> check_constraint(:recovered_from_execution_id,
      name: :execution_records_recovery_root_check
    )
    |> check_constraint(:root_execution_id, name: :execution_records_root_status_check)
    |> check_constraint(:status, name: :execution_records_status_check)
    |> check_constraint(:public_answer_message_id, name: :execution_records_answer_status_check)
    |> check_constraint(:public_answer_message_id, name: :execution_records_distinct_answer_check)
    |> check_constraint(:finalization_token_hash, name: :execution_records_capability_hash_check)
  end

  @doc "Sets the Engine-owned reservation once; ordinary attribute casting cannot allocate it."
  @spec reservation_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def reservation_changeset(record, answer_id) do
    record
    |> change()
    |> put_change(:reserved_answer_message_id, answer_id)
    |> validate_required([:reserved_answer_message_id])
    |> validate_change(:reserved_answer_message_id, fn field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, ^value} -> []
        _ -> [{field, "must be a canonical UUID"}]
      end
    end)
    |> validate_answer_reservation()
    |> validate_immutable_identity()
    |> unique_constraint(:reserved_answer_message_id)
    |> check_constraint(:reserved_answer_message_id,
      name: :execution_records_answer_reservation_check
    )
  end

  @doc "Changes only the owner during an explicitly authorized People merge."
  def owner_changeset(record, person_id) do
    record
    |> cast(%{person_id: person_id}, [:person_id])
    |> validate_required([:person_id])
    |> validate_number(:person_id, greater_than: 0)
    |> foreign_key_constraint(:person_id)
  end

  defp validate_immutable_identity(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    changeset
    |> immutable_fields([
      :person_id,
      :user_message_id,
      :finalization_token_hash,
      :recovered_from_execution_id
    ])
    |> immutable_root()
    |> immutable_answer()
    |> immutable_reservation()
    |> immutable_terminal_status()
  end

  defp validate_immutable_identity(changeset), do: changeset

  defp immutable_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(changeset.changes, field),
        do: add_error(changeset, field, "cannot rebind execution identity"),
        else: changeset
    end)
  end

  defp immutable_root(
         %{data: %{status: "pending", root_execution_id: nil, reserved_answer_message_id: nil}} =
           changeset
       ),
       do: changeset

  defp immutable_root(changeset), do: immutable_fields(changeset, [:root_execution_id])

  defp immutable_answer(%{data: %{public_answer_message_id: nil}} = changeset), do: changeset
  defp immutable_answer(changeset), do: immutable_fields(changeset, [:public_answer_message_id])

  defp immutable_reservation(%{data: %{reserved_answer_message_id: nil}} = changeset),
    do: changeset

  defp immutable_reservation(changeset),
    do: immutable_fields(changeset, [:reserved_answer_message_id])

  defp immutable_terminal_status(%{data: %{status: status}} = changeset)
       when status in ["completed", "failed", "consumed", "unconsumed"],
       do: immutable_fields(changeset, [:status])

  defp immutable_terminal_status(changeset), do: changeset

  defp validate_answer_status(changeset) do
    user_message_id = get_field(changeset, :user_message_id)

    case {get_field(changeset, :status), get_field(changeset, :public_answer_message_id)} do
      {"completed", nil} ->
        add_error(changeset, :public_answer_message_id, "is required for completed execution")

      {status, id} when status != "completed" and not is_nil(id) ->
        add_error(changeset, :public_answer_message_id, "requires completed execution")

      {_status, ^user_message_id} when not is_nil(user_message_id) ->
        add_error(changeset, :public_answer_message_id, "must differ from the input message")

      _ ->
        changeset
    end
  end

  defp validate_root_status(changeset) do
    root = get_field(changeset, :root_execution_id)
    id = get_field(changeset, :id)
    status = get_field(changeset, :status)

    cond do
      not is_nil(root) and root == id ->
        add_error(changeset, :root_execution_id, "must differ from the child execution")

      is_nil(root) and status in @receipt_statuses ->
        add_error(changeset, :root_execution_id, "is required for input receipts")

      not is_nil(root) and status in @root_statuses ->
        add_error(changeset, :status, "requires a root execution")

      true ->
        changeset
    end
  end

  defp validate_answer_reservation(changeset) do
    reserved = get_field(changeset, :reserved_answer_message_id)
    answer = get_field(changeset, :public_answer_message_id)

    cond do
      is_nil(reserved) ->
        changeset

      not is_nil(get_field(changeset, :root_execution_id)) ->
        add_error(changeset, :reserved_answer_message_id, "requires an answer root")

      reserved == get_field(changeset, :user_message_id) ->
        add_error(changeset, :reserved_answer_message_id, "must differ from the input message")

      not is_nil(answer) and answer != reserved ->
        add_error(changeset, :public_answer_message_id, "must match the reserved answer identity")

      true ->
        changeset
    end
  end
end
