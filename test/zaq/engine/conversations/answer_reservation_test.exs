defmodule Zaq.Engine.Conversations.AnswerReservationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Conversation, ExecutionRecord, Message}

  test "reservation is stable without creating a Message or a persisted-answer link" do
    {input, execution, token, opts} = fixture()
    count = Repo.aggregate(Message, :count)

    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token, opts)
    assert Ecto.UUID.cast(binding.assistant_message_id) == {:ok, binding.assistant_message_id}
    assert binding.public_answer_message_id == nil
    assert binding.assistant_message_id != input.id
    assert {:ok, ^binding} = Conversations.reserve_answer_identity(input.id, token, opts)
    assert Repo.aggregate(Message, :count) == count
    stored = Repo.get!(ExecutionRecord, execution.id)
    assert stored.reserved_answer_message_id == binding.assistant_message_id
    assert stored.public_answer_message_id == nil
    assert stored.status == "pending"
  end

  test "legacy Message-only admission reserves under the same input without creating private execution" do
    {input, _execution, token, _opts} = fixture(legacy: true)
    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token)
    assert {:ok, ^binding} = Conversations.reserve_answer_identity(input.id, token)
    assert Repo.aggregate(ExecutionRecord, :count) == 0

    assert Repo.get!(Message, input.id).metadata["reserved_answer_message_id"] ==
             binding.assistant_message_id
  end

  test "completed roots adopt their persisted UUID rather than allocating another" do
    {input, execution, token, opts} = fixture()
    answer = message(input.conversation_id, "assistant", %{})

    execution
    |> ExecutionRecord.changeset(%{status: "completed", public_answer_message_id: answer.id})
    |> Repo.update!()

    assert {:ok, %{assistant_message_id: id, public_answer_message_id: id}} =
             Conversations.reserve_answer_identity(input.id, token, opts)

    assert id == answer.id
    assert Repo.get!(ExecutionRecord, execution.id).reserved_answer_message_id == id
  end

  test "legacy completed answers retain their canonical UUID and conflicting metadata fails closed" do
    {input, _execution, token, _opts} = fixture(legacy: true)

    input
    |> Ecto.Changeset.change(metadata: Map.put(input.metadata, "execution_status", "completed"))
    |> Repo.update!()

    assert {:error, :answer_identity_conflict} =
             Conversations.reserve_answer_identity(input.id, token)

    answer = message(input.conversation_id, "assistant", %{"in_reply_to_message_id" => input.id})

    assert {:ok, %{assistant_message_id: id, public_answer_message_id: id}} =
             Conversations.reserve_answer_identity(input.id, token)

    assert id == answer.id

    stored = Repo.get!(Message, input.id)

    stored
    |> Ecto.Changeset.change(
      metadata: Map.put(stored.metadata, "reserved_answer_message_id", Ecto.UUID.generate())
    )
    |> Repo.update!()

    assert {:error, :answer_identity_conflict} =
             Conversations.reserve_answer_identity(input.id, token)
  end

  test "handled failure preserves an existing reservation without creating an assistant answer" do
    {input, execution, token, opts} = fixture()
    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token, opts)

    assert {:ok, _finalized} =
             Conversations.finalize_incoming(input.id, token, %{error: true}, opts)

    assert Repo.get!(ExecutionRecord, execution.id).reserved_answer_message_id ==
             binding.assistant_message_id

    assert {:ok, ^binding} = Conversations.reserve_answer_identity(input.id, token, opts)
  end

  test "a failed answer insert rolls back finalization without discarding the reservation" do
    {input, execution, token, opts} = fixture()
    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token, opts)

    assert {:error, _reason} =
             Conversations.finalize_incoming(
               input.id,
               token,
               %{answer: "Answer", confidence_score: "not-a-number"},
               opts
             )

    stored = Repo.get!(ExecutionRecord, execution.id)
    assert stored.status == "pending"
    assert stored.reserved_answer_message_id == binding.assistant_message_id
    assert stored.public_answer_message_id == nil
    assert {:ok, ^binding} = Conversations.reserve_answer_identity(input.id, token, opts)
  end

  test "capability, exact execution and active owner are checked before reservation" do
    {input, execution, token, opts} = fixture()

    assert {:error, :invalid_finalization_token} =
             Conversations.reserve_answer_identity(input.id, "wrong", opts)

    assert {:error, :unauthorized} =
             Conversations.reserve_answer_identity(
               input.id,
               token,
               Keyword.put(opts, :actor, nil)
             )

    assert {:error, :unauthorized} =
             Conversations.reserve_answer_identity(
               input.id,
               token,
               Keyword.put(opts, :execution_id, Ecto.UUID.generate())
             )

    assert Repo.get!(ExecutionRecord, execution.id).reserved_answer_message_id == nil
  end

  test "provisional and unsuccessful roots do not reserve an answer" do
    {input, execution, token, opts} = fixture(admitted: false)

    assert {:error, :admission_required} =
             Conversations.reserve_answer_identity(input.id, token, opts)

    execution |> ExecutionRecord.changeset(%{status: "failed"}) |> Repo.update!()

    assert {:error, :terminal_request} =
             Conversations.reserve_answer_identity(input.id, token, opts)

    assert Repo.get!(ExecutionRecord, execution.id).reserved_answer_message_id == nil
  end

  test "a child receipt cannot reserve a second answer" do
    {input, execution, token, opts} = fixture()
    root_input = message(input.conversation_id, "user", %{})

    root =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: execution.person_id,
        user_message_id: root_input.id,
        finalization_token_hash: hash("root-token")
      })
      |> Repo.insert!()

    execution
    |> ExecutionRecord.changeset(%{root_execution_id: root.id, status: "queued"})
    |> Repo.update!()

    assert {:error, :input_not_root} =
             Conversations.reserve_answer_identity(input.id, token, opts)

    assert Repo.get!(ExecutionRecord, execution.id).reserved_answer_message_id == nil
  end

  test "a reservation cannot be rebound, converted to a receipt or linked to a different answer" do
    {input, execution, token, opts} = fixture()
    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token, opts)
    execution = Repo.get!(ExecutionRecord, execution.id)

    refute ExecutionRecord.reservation_changeset(execution, Ecto.UUID.generate()).valid?
    assert ExecutionRecord.reservation_changeset(execution, binding.assistant_message_id).valid?

    refute ExecutionRecord.changeset(execution, %{
             root_execution_id: Ecto.UUID.generate(),
             status: "queued"
           }).valid?

    answer = message(input.conversation_id, "assistant", %{})

    refute ExecutionRecord.changeset(execution, %{
             status: "completed",
             public_answer_message_id: answer.id
           }).valid?
  end

  test "database constraints reject duplicate, input and receipt reservations" do
    {input, execution, token, opts} = fixture()
    assert {:ok, binding} = Conversations.reserve_answer_identity(input.id, token, opts)
    {other_input, other, _token, _opts} = fixture()

    for attrs <- [
          [reserved_answer_message_id: binding.assistant_message_id],
          [reserved_answer_message_id: other_input.id],
          [
            reserved_answer_message_id: Ecto.UUID.generate(),
            root_execution_id: execution.id,
            status: "queued"
          ]
        ] do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn ->
          other |> Ecto.Changeset.change(attrs) |> Repo.update!()
        end)
      end
    end
  end

  test "malformed and missing input bindings fail closed" do
    assert {:error, :unauthorized} = Conversations.reserve_answer_identity("not-uuid", "token")
    assert {:error, :invalid_answer_reservation} = Conversations.reserve_answer_identity(nil, nil)

    assert {:error, :user_message_not_found} =
             Conversations.reserve_answer_identity(Ecto.UUID.generate(), "token")
  end

  defp fixture(opts \\ []) do
    {:ok, person} = People.create_person(%{full_name: "Answer reservation"})

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{channel_type: "api", person_id: person.id})
      |> Repo.insert!()

    token = Ecto.UUID.generate()

    input =
      message(conversation.id, "user", %{
        "execution_status" => "pending",
        "finalization_token_hash" => hash(token)
      })

    execution =
      unless opts[:legacy] do
        %ExecutionRecord{}
        |> ExecutionRecord.changeset(%{
          person_id: person.id,
          user_message_id: input.id,
          finalization_token_hash: hash(token)
        })
        |> Ecto.Changeset.put_change(
          :admitted_at,
          if(Keyword.get(opts, :admitted, true), do: DateTime.utc_now())
        )
        |> Repo.insert!()
      end

    {input, execution, token,
     [execution_id: execution && execution.id, actor: %{person: %{id: person.id}}]}
  end

  defp message(conversation_id, role, metadata) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation_id,
      role: role,
      content: "Content",
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode64()
end
