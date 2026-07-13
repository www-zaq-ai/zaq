defmodule Zaq.Agent.Tools.People.NotifyPersonThreadingTest do
  @moduledoc """
  Step 5: `NotifyPerson` surfaces the abstraction's *generic* threading fields so
  the workflow edge can carry them to the persist step.

  `message_id` and `thread_id` are cross-channel concepts (a chat post has both
  too), so they belong on the contract. `references` is the one genuinely
  email-only piece and must never appear as a named field — it rides inside the
  opaque `thread_metadata` residue, which `NotifyPerson` never interprets.
  """
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.People.NotifyPerson

  defmodule StubRouter do
    def dispatch(event) do
      %{event | response: Process.get(:notify_response)}
    end
  end

  defp run(response, person \\ %{id: 7, full_name: "Lead"}) do
    Process.put(:notify_response, response)

    NotifyPerson.run(
      %{person: person, subject: "Topic A", message: "hello"},
      %{node_router: StubRouter}
    )
  end

  defp sent_result do
    {:ok,
     %{
       status: :sent,
       notification_log_id: 1,
       channel: "email:smtp",
       channel_identifier: "lead@example.test",
       message_id: "new@zaq.local",
       thread_id: "m0@zaq.local",
       thread_metadata: %{
         "email" => %{
           "threading" => %{
             "message_id" => "new@zaq.local",
             "in_reply_to" => "m1@zaq.local",
             "references" => ["m0@zaq.local", "m1@zaq.local"]
           }
         }
       }
     }}
  end

  describe "sent email" do
    test "surfaces the generic message_id and thread_id" do
      assert {:ok, out} = run(sent_result())

      assert out.notified == true
      assert out.message_id == "new@zaq.local"
      assert out.thread_id == "m0@zaq.local"
    end

    test "carries the email-only references chain inside the opaque thread_metadata" do
      assert {:ok, out} = run(sent_result())

      assert out.thread_metadata["email"]["threading"]["references"] == [
               "m0@zaq.local",
               "m1@zaq.local"
             ]

      assert out.thread_metadata["email"]["threading"]["in_reply_to"] == "m1@zaq.local"
    end

    test "never exposes references as a named field — it is not a cross-channel concept" do
      assert {:ok, out} = run(sent_result())

      refute Map.has_key?(out, :references)
    end
  end

  describe "not sent (Bug #3)" do
    test "a skipped notification surfaces no threading fields" do
      assert {:ok, out} = run({:ok, %{status: :skipped, notification_log_id: nil}})

      assert out.notified == false
      assert out.message_id == nil
      assert out.thread_id == nil
      assert out.thread_metadata == %{}
    end

    test "a channel that threads nothing (chat, pre-arm-2) surfaces empty threading" do
      assert {:ok, out} =
               run(
                 {:ok,
                  %{
                    status: :sent,
                    notification_log_id: 2,
                    channel: "mattermost",
                    channel_identifier: "U1"
                  }}
               )

      assert out.notified == true
      assert out.message_id == nil
      assert out.thread_metadata == %{}
    end
  end

  describe "output schema" do
    test "declares the generic threading fields and no email-specific one" do
      keys = NotifyPerson.__action_metadata__()[:output_schema] |> Keyword.keys()

      assert :message_id in keys
      assert :thread_id in keys
      assert :thread_metadata in keys
      # The email leak this design deliberately avoids.
      refute :references in keys
    end
  end
end
