unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddReservedAnswerIdentity) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261016000000_add_reserved_answer_identity.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Conversations.AnswerReservationMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Repo.Migrations.AddReservedAnswerIdentity

  @version 20_261_016_000_000
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "empty and populated upgrades preserve existing answers and private evidence" do
    round_trip()
    person = Repo.insert!(%Person{full_name: "Reservation migration"})
    pending = execution(person, "pending", nil)
    answer = message("assistant")
    completed = execution(person, "completed", answer.id)

    round_trip()

    assert Repo.get!(ExecutionRecord, pending.id) == pending

    assert Repo.get!(ExecutionRecord, completed.id) ==
             %{completed | reserved_answer_message_id: answer.id}

    assert Repo.get!(Message, answer.id) == answer
  end

  test "rollback refuses to discard reserved identities without persisted answers" do
    person = Repo.insert!(%Person{full_name: "Reservation rollback"})
    root = execution(person, "pending", nil)

    reserved =
      root
      |> ExecutionRecord.reservation_changeset(Ecto.UUID.generate())
      |> Repo.update!()

    assert_raise Postgrex.Error, ~r/Cannot remove reserved answer identities/, fn ->
      Ecto.Migrator.down(Repo, @version, AddReservedAnswerIdentity, @opts)
    end

    assert Repo.get!(ExecutionRecord, root.id) == reserved
  end

  defp round_trip do
    assert :ok = Ecto.Migrator.down(Repo, @version, AddReservedAnswerIdentity, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddReservedAnswerIdentity, @opts)
  end

  defp execution(person, status, answer_id) do
    input = message("user")

    %ExecutionRecord{}
    |> ExecutionRecord.changeset(%{
      person_id: person.id,
      user_message_id: input.id,
      status: status,
      public_answer_message_id: answer_id,
      finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
      trace_entries: [%{"private" => "preserved"}],
      usage: %{"prompt_tokens" => 9}
    })
    |> Repo.insert!()
  end

  defp message(role),
    do:
      %Message{}
      |> Message.canonical_changeset(%{role: role, content: "Content"})
      |> Repo.insert!()
end
