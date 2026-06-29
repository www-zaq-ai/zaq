defmodule Zaq.Engine.Messages.OutgoingTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  test "from_pipeline_result carries canonical person in metadata" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      person: %{id: 42, full_name: "Ada", team_ids: [7]}
    }

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "ok"})

    assert outgoing.metadata.person == %{id: 42, full_name: "Ada", team_ids: [7]}
    refute Map.has_key?(outgoing.metadata, :person_id)
  end

  test "from_pipeline_result omits person metadata when incoming has no person" do
    incoming = %Incoming{content: "hello", channel_id: "c1", provider: :mattermost}

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "ok"})

    refute Map.has_key?(outgoing.metadata, :person)
    refute Map.has_key?(outgoing.metadata, :person_id)
  end
end
