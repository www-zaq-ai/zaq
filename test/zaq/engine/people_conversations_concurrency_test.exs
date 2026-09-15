defmodule Zaq.Engine.PeopleConversationsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, Person, Team}
  alias Zaq.Engine.{Conversations, PeopleConversations}
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Repo

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, team} =
          People.create_team(%{name: "History locks #{System.unique_integer([:positive])}"})

        {:ok, person} = People.create_person(%{full_name: "Lock owner", team_ids: [team.id]})
        {:ok, survivor} = People.create_person(%{full_name: "Lock survivor", team_ids: [team.id]})

        for permission <- [:access_profile, :access_message_history, :share_conversations],
            do: PeoplePermissions.grant({:team, team.id}, permission)

        {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 9, 6, 1})

        {:ok, %{token: token}} =
          PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

        {:ok, conversation} =
          Conversations.create_conversation(%{
            title: "Locks",
            person_id: person.id,
            channel_type: "api"
          })

        {:ok, message} =
          Conversations.add_message(conversation, %{role: "assistant", content: "Locks"})

        %{
          team: team,
          person: person,
          survivor: survivor,
          token: token,
          conversation: conversation,
          message: message
        }
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Conversation, where: c.id == ^fixture.conversation.id)
        ids = [fixture.person.id, fixture.survivor.id]
        Repo.delete_all(from p in Person, where: p.id in ^ids)
        Repo.delete_all(from t in Team, where: t.id == ^fixture.team.id)
      end)
    end)

    fixture
  end

  for operation <- [:rate, :share], mutation <- [:revoke, :merge] do
    test "#{operation} retains auth locks through writes against #{mutation}", fixture do
      operation = unquote(operation)
      mutation = unquote(mutation)
      parent = self()
      barrier = make_ref()

      writer =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handler = {__MODULE__, barrier}

            :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.pause_parent/4, %{
              owner: self(),
              parent: parent,
              barrier: barrier
            })

            try do
              PeopleConversations.dispatch(
                %{
                  op: operation,
                  token: fixture.token,
                  conversation_id: fixture.conversation.id,
                  message_id: fixture.message.id,
                  attrs: %{rating: 5, permission: "read"}
                },
                []
              )
            after
              :telemetry.detach(handler)
            end
          end)
        end)

      try do
        assert_receive {:parent_locked, ^barrier}, 5_000
        # A real independent connection must be unable to revoke/merge while the
        # gateway is paused immediately before its write, after authentication.
        error =
          assert_raise Postgrex.Error, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.query!("SET LOCAL lock_timeout = '100ms'")
                mutate(mutation, fixture)
              end)
            end)
          end

        assert error.postgres.code == :lock_not_available
        send(writer.pid, {:resume, barrier})
        assert {:ok, _} = Task.await(writer, 5_000)

        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _} = mutate(mutation, fixture)

          assert {:error, :invalid_session} =
                   PeopleConversations.dispatch(
                     %{
                       op: operation,
                       token: fixture.token,
                       conversation_id: fixture.conversation.id,
                       message_id: fixture.message.id,
                       attrs: %{rating: 1, permission: "read"}
                     },
                     []
                   )
        end)
      after
        send(writer.pid, {:resume, barrier})
        Task.shutdown(writer)
      end
    end
  end

  defp mutate(:revoke, fixture), do: PeopleAuth.revoke_session(fixture.token)
  defp mutate(:merge, fixture), do: People.merge_persons(fixture.survivor, fixture.person)

  @doc "Test synchronization at the completed parent-lock query, using real Repo telemetry."
  def pause_parent(_, _, %{query: query}, config) do
    if self() == config.owner and String.contains?(query, "FROM \"conversations\"") and
         String.contains?(query, "FOR UPDATE") do
      send(config.parent, {:parent_locked, config.barrier})

      receive do
        {:resume, barrier} when barrier == config.barrier -> :ok
      after
        10_000 -> raise "Parent lock barrier was not released"
      end
    end
  end
end
