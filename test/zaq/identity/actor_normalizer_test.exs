defmodule Zaq.Identity.ActorNormalizerTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer

  test "from_incoming enriches actor with incoming person" do
    incoming = incoming(%{id: 42, full_name: "Alice", team_ids: [1, "2", "bad"]})

    actor = ActorNormalizer.from_incoming(%{id: "channel-user", name: "alice"}, incoming)

    assert actor.id == "channel-user"
    assert actor.name == "alice"
    assert actor.provider == :mattermost
    assert actor.person == %{id: 42, full_name: "Alice", team_ids: [1, 2]}
  end

  test "from_incoming preserves an existing actor person" do
    incoming = incoming(%{id: 42, full_name: "Alice", team_ids: [1]})
    actor = %{person: %{id: 7, full_name: "Bob", team_ids: [3]}}

    assert ActorNormalizer.from_incoming(actor, incoming).person.id == 7
  end

  test "from_event_request derives actor from event request" do
    event = Event.new(incoming(%{id: 42, full_name: "Alice", team_ids: []}), :agent)

    assert %{actor: %{person: %{id: 42}}} = ActorNormalizer.normalize_event(event)
  end

  test "person helpers tolerate persisted string-key actors and legacy flat person_id" do
    actor = %{"person" => %{"id" => "42", "team_ids" => ["1", 2]}}

    assert ActorNormalizer.person_id(actor) == 42
    assert ActorNormalizer.team_ids(actor) == [1, 2]
    assert ActorNormalizer.person_id(%{"person_id" => "9"}) == 9
  end

  test "missing person does not fabricate actor identity" do
    incoming = incoming(nil)

    assert ActorNormalizer.from_incoming(nil, incoming) == nil

    assert ActorNormalizer.person_id(nil) == nil
    assert ActorNormalizer.team_ids(nil) == []
  end

  defp incoming(person) do
    Incoming.new(%{
      content: "hello",
      channel_id: "c1",
      author_id: "u1",
      author_name: "Alice",
      provider: :mattermost,
      person: person
    })
  end
end
