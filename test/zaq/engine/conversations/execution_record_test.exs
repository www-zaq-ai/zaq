defmodule Zaq.Engine.Conversations.ExecutionRecordTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript}
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defp person do
    {:ok, person} = People.create_person(%{"full_name" => "Execution Owner"})
    person
  end

  defp message(role, content) do
    %Message{}
    |> Message.canonical_changeset(%{role: role, content: content})
    |> Repo.insert!()
  end

  defp capability(seed) do
    seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()
  end

  defp execution_attrs(owner, input, overrides) do
    Map.merge(
      %{
        person_id: owner.id,
        user_message_id: input.id,
        status: "pending",
        finalization_token_hash: capability(Ecto.UUID.generate()),
        trace_entries: [%{"step" => "retrieval", "private" => "internal context"}],
        tool_results: [%{"tool" => "search", "private" => "internal result"}],
        usage: %{"prompt_tokens" => 31},
        outcome: %{"request_id" => "request-1"}
      },
      overrides
    )
  end

  test "a Person-bound private execution references canonical content without copying its trace" do
    owner = person()
    input = message("user", "Where is the document?")
    answer = message("assistant", "It is in the knowledge base.")

    execution =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(
        execution_attrs(owner, input, %{
          status: "completed",
          public_answer_message_id: answer.id
        })
      )
      |> Repo.insert!()

    assert execution.person_id == owner.id
    assert execution.user_message_id == input.id
    assert execution.public_answer_message_id == answer.id
    assert execution.trace_entries == [%{"step" => "retrieval", "private" => "internal context"}]
    assert execution.usage == %{"prompt_tokens" => 31}
    assert Repo.get!(Message, answer.id).trace == []
    assert Repo.get!(Message, answer.id).metadata == %{}
    assert Repo.get!(Message, input.id).trace == []
  end

  test "an authorized transcript read never includes a linked execution capability or trace" do
    owner = person()

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Execution channel",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "fixture-token"
      })
      |> Repo.insert!()

    {type, resource_id} = ChannelHistoryResource.for("mattermost", config.id, "room-1")

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: "shared",
        provider: "mattermost",
        channel_config_id: config.id,
        scope_key: "room-1",
        external_channel_id: "room-1",
        permission_resource_type: type,
        permission_resource_id: resource_id
      })
      |> Repo.insert!()

    context = %{
      provider: "mattermost",
      channel_config_id: config.id,
      provenance: "provider_event"
    }

    assert {:ok, %{message_id: input_id}} =
             Conversations.append_canonical_message(
               transcript.id,
               %{role: "user", content: "Question", external_message_id: "user-post-1"},
               context
             )

    assert {:ok, %{message_id: answer_id}} =
             Conversations.append_canonical_message(
               transcript.id,
               %{role: "assistant", content: "Answer", external_message_id: "bot-post-1"},
               context
             )

    execution =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(
        execution_attrs(owner, Repo.get!(Message, input_id), %{
          status: "completed",
          public_answer_message_id: answer_id
        })
      )
      |> Repo.insert!()

    assert {:ok, _} =
             Permissions.grant({type, resource_id}, %{
               person_id: owner.id,
               access_rights: ["read"]
             })

    assert {:ok, history} = Conversations.list_canonical_messages(owner, transcript.id)
    assert Enum.map(history, & &1.message_id) == [input_id, answer_id]
    assert Enum.map(history, & &1.content) == ["Question", "Answer"]
    assert execution.trace_entries != []

    for item <- history do
      refute Map.has_key?(item, :trace_entries)
      refute Map.has_key?(item, :tool_results)
      refute Map.has_key?(item, :usage)
      refute Map.has_key?(item, :finalization_token_hash)
    end
  end

  test "a public answer cannot belong to two executions, even for different people" do
    first_owner = person()
    second_owner = person()
    input = message("user", "Question")
    answer = message("assistant", "Answer")

    first =
      execution_attrs(first_owner, input, %{
        status: "completed",
        public_answer_message_id: answer.id
      })

    assert {:ok, _} = %ExecutionRecord{} |> ExecutionRecord.changeset(first) |> Repo.insert()

    second =
      execution_attrs(second_owner, input, %{
        status: "completed",
        public_answer_message_id: answer.id
      })

    assert {:error, duplicate} =
             %ExecutionRecord{} |> ExecutionRecord.changeset(second) |> Repo.insert()

    assert %{public_answer_message_id: _} = errors_on(duplicate)
  end

  test "incomplete ownership or a raw capability is rejected before persistence" do
    input = message("user", "Question")
    owner = person()

    assert %{person_id: _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(execution_attrs(owner, input, %{person_id: nil}))
             |> errors_on()

    assert %{finalization_token_hash: _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(
               execution_attrs(owner, input, %{finalization_token_hash: "raw-secret-token"})
             )
             |> errors_on()

    assert {:error, missing_person} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(
               execution_attrs(owner, input, %{person_id: 999_999_999})
             )
             |> Repo.insert()

    assert %{person_id: _} = errors_on(missing_person)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        Repo.insert!(%ExecutionRecord{
          person_id: owner.id,
          user_message_id: input.id,
          status: "pending",
          finalization_token_hash: "raw-secret-token"
        })
      end)
    end
  end

  test "a capability hash cannot authorize two execution records" do
    owner = person()
    input = message("user", "Question")
    hash = capability("same-token")
    attrs = execution_attrs(owner, input, %{finalization_token_hash: hash})
    assert {:ok, _} = %ExecutionRecord{} |> ExecutionRecord.changeset(attrs) |> Repo.insert()

    assert {:error, duplicate} =
             %ExecutionRecord{} |> ExecutionRecord.changeset(attrs) |> Repo.insert()

    assert %{finalization_token_hash: _} = errors_on(duplicate)
  end

  test "pending and failed executions cannot claim an answer; completed executions require one" do
    owner = person()
    input = message("user", "Question")
    answer = message("assistant", "Answer")

    for status <- ["pending", "failed"] do
      assert %{public_answer_message_id: _} =
               %ExecutionRecord{}
               |> ExecutionRecord.changeset(
                 execution_attrs(owner, input, %{
                   status: status,
                   public_answer_message_id: answer.id
                 })
               )
               |> errors_on()
    end

    assert %{public_answer_message_id: _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(execution_attrs(owner, input, %{status: "completed"}))
             |> errors_on()

    assert %{status: _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(execution_attrs(owner, input, %{status: "unknown"}))
             |> errors_on()

    assert %{public_answer_message_id: _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(
               execution_attrs(owner, input, %{
                 status: "completed",
                 public_answer_message_id: input.id
               })
             )
             |> errors_on()
  end

  property "different request capabilities never become one execution identity" do
    owner = person()
    input = message("user", "Question")

    check all(
            seed <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            max_runs: 15
          ) do
      hash = capability("#{System.unique_integer([:positive])}:#{seed}")

      assert {:ok, run} =
               %ExecutionRecord{}
               |> ExecutionRecord.changeset(
                 execution_attrs(owner, input, %{finalization_token_hash: hash})
               )
               |> Repo.insert()

      assert run.finalization_token_hash == hash
      assert run.public_answer_message_id == nil
    end
  end
end
