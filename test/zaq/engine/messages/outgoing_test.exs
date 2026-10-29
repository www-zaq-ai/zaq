defmodule Zaq.Engine.Messages.OutgoingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  test "attachments default to empty for direct and pipeline messages" do
    incoming = incoming()

    assert Map.fetch!(
             %Outgoing{body: "ok", channel_id: "c1", provider: :mattermost},
             :attachments
           ) ==
             []

    for result <- [%{answer: "ok"}, %{answer: "ok", attachments: []}] do
      assert Map.fetch!(Outgoing.from_pipeline_result(incoming, result), :attachments) == []
    end
  end

  test "only explicit result records become outbound attachments" do
    received = %Record{id: "received", kind: :file, name: "received.txt"}
    requested = %Record{id: "requested", kind: :file, content: "report", name: "report.txt"}
    incoming = %{incoming() | attachments: [received]}

    assert Map.fetch!(Outgoing.from_pipeline_result(incoming, %{answer: "ok"}), :attachments) ==
             []

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "ok", attachments: [requested]})
    assert Map.fetch!(outgoing, :attachments) == [requested]
    assert outgoing.in_reply_to == "m1"
  end

  test "attachment validation is deferred without losing the answer or supplied values" do
    record = %Record{id: "file", kind: :file}

    for attachments <- [nil, "file", %{}, record, [%{id: "file", kind: :file}], [record, nil]] do
      outgoing =
        Outgoing.from_pipeline_result(incoming(), %{answer: "ok", attachments: attachments})

      assert %Outgoing{body: "ok", attachments: ^attachments} = outgoing
      refute Map.has_key?(outgoing.metadata, :attachments)
    end
  end

  test "runtime attachments do not duplicate into merged metadata" do
    record = %Record{id: "file", kind: :file, content: "bytes"}

    incoming = %{
      incoming()
      | metadata: %{:attachments => [record], "attachments" => [record], :kept => 1}
    }

    outgoing =
      Outgoing.from_pipeline_result(incoming, %{
        :answer => "ok",
        :attachments => [record],
        "attachments" => [record],
        :confidence_score => 0.9
      })

    assert outgoing.metadata == %{answer: "ok", confidence_score: 0.9, kept: 1}
    assert Map.fetch!(outgoing, :attachments) == [record]
  end

  property "explicit records retain their order and never leak into metadata" do
    check all(ids <- list_of(string(:alphanumeric, min_length: 1), max_length: 12)) do
      records = Enum.map(ids, &%Record{id: &1, kind: :file, name: &1, content: &1})
      incoming = %{incoming() | attachments: [%Record{id: "incoming-only", kind: :file}]}
      result = %{answer: "ok", attachments: records, tokens: 12}

      outgoing = Outgoing.from_pipeline_result(incoming, result)
      assert Map.fetch!(outgoing, :attachments) == records
      assert outgoing.metadata == %{answer: "ok", tokens: 12}
      assert Outgoing.from_pipeline_result(incoming, result) == outgoing
    end
  end

  property "non-record values do not block outgoing construction or change supplied attachments" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            invalid <- one_of([integer(), string(:alphanumeric), constant(nil), constant(%{})])
          ) do
      records = [%Record{id: id, kind: :file}, invalid]

      outgoing = Outgoing.from_pipeline_result(incoming(), %{answer: "ok", attachments: records})
      assert %Outgoing{body: "ok", attachments: ^records} = outgoing
      refute Map.has_key?(outgoing.metadata, :attachments)
    end
  end

  test "from_pipeline_result preserves stamped routing independently of metadata" do
    context = %RoutingContext{channel_config_id: 42}

    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: context,
      metadata: %{channel_config_id: 99}
    }

    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "ok"})
    assert outgoing.routing_context == context
    assert outgoing.metadata.channel_config_id == 99
  end

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

  defp incoming do
    %Incoming{content: "hello", channel_id: "c1", message_id: "m1", provider: :mattermost}
  end
end
