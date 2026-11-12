defmodule Zaq.Engine.OptionalTraceArtifactsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.ConversationLifecycleFixtures
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Incoming

  property "only explicit optional artifacts may be omitted at the configured size boundary" do
    check all(
            size <- integer(1..32),
            limit <- integer(1..32),
            optional <- member_of([true, false, nil, "true", 1]),
            string_keys? <- boolean(),
            max_runs: 20
          ) do
      artifact = %{
        content: String.duplicate("x", size),
        name: "document",
        mime_type: "text/plain",
        tool_call_id: "child",
        tool_name: "download",
        optional: optional
      }

      artifact =
        if string_keys?,
          do: Map.new(artifact, fn {key, value} -> {to_string(key), value} end),
          else: artifact

      incoming = %Incoming{
        content: "Inspect document",
        channel_id: Ecto.UUID.generate(),
        author_id: Ecto.UUID.generate(),
        provider: :mattermost
      }

      result = %{
        answer: "Completed answer",
        trace: [%{"id" => "child", "type" => "tool_call", "outcome" => "succeeded"}],
        trace_artifacts: [artifact]
      }

      outcome =
        ConversationLifecycleFixtures.complete_exchange(incoming, result,
          artifact_max_bytes: limit
        )

      if size > limit and optional != true do
        assert outcome == {:error, :trace_artifact_too_large}
      else
        assert {:ok, %{assistant_message_id: id}} = outcome
        persisted = Repo.get!(Message, id)
        assert persisted.content == "Completed answer"
        assert [child] = persisted.trace

        if size > limit do
          assert child["artifact_omissions"] == [%{"reason" => "trace_artifact_too_large"}]
          refute Map.has_key?(child, "artifacts")
        else
          assert [descriptor] = child["artifacts"]
          assert descriptor["size"] == size
          refute Map.has_key?(child, "artifact_omissions")
        end
      end
    end
  end
end
