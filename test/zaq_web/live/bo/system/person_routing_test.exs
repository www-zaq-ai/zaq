defmodule ZaqWeb.Live.BO.System.PersonRoutingTest do
  use Zaq.DataCase, async: true

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Channels.AgentRouting
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.System.PersonRouting

  test "nil person produces default values for every routing scope" do
    assert PersonRouting.person_global_agent_value(nil) == ""
    assert PersonRouting.person_provider_agent_value(nil, %ChannelConfig{id: 1}) == ""
    assert PersonRouting.person_retrieval_agent_value(nil, %RetrievalChannel{id: 1}) == ""
    assert PersonRouting.person_topic_agent_value(nil, %ChannelConfig{id: 1}, "INBOX") == ""
  end

  test "non-channel values have no available routing configs" do
    assert PersonRouting.person_channel_routing_configs(nil) == []
    assert PersonRouting.person_channel_routing_configs(%{}) == []
  end

  test "malformed provider config key returns invalid routing choice without persisting" do
    person = person_fixture()

    assert PersonRouting.maybe_persist_channel_routing_rules(person.id, %{
             "provider_agent_ids" => %{"not-an-id" => AgentRouting.none_value()}
           }) == {:error, :invalid_routing_choice}

    assert_no_person_routing_rules(person)
  end

  test "invalid provider choice returns its validation error without persisting" do
    person = person_fixture()

    assert PersonRouting.maybe_persist_channel_routing_rules(person.id, %{
             "provider_agent_ids" => %{"1" => "bad-agent-choice"}
           }) == {:error, :invalid_agent}

    assert_no_person_routing_rules(person)
  end

  test "malformed retrieval channel key returns invalid channel without persisting" do
    person = person_fixture()

    assert PersonRouting.maybe_persist_channel_routing_rules(person.id, %{
             "retrieval_agent_ids" => %{"not-an-id" => AgentRouting.none_value()}
           }) == {:error, :invalid_retrieval_channel}

    assert_no_person_routing_rules(person)
  end

  test "malformed topic config key returns invalid topic rule without persisting" do
    person = person_fixture()

    assert PersonRouting.maybe_persist_channel_routing_rules(person.id, %{
             "topic_agent_ids" => %{
               "not-an-id" => %{"INBOX" => AgentRouting.none_value()}
             }
           }) == {:error, :invalid_topic_rule}

    assert_no_person_routing_rules(person)
  end

  defp person_fixture do
    unique_id = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Person Routing #{unique_id}",
        "email" => "person-routing-#{unique_id}@example.com"
      })

    person
  end

  defp assert_no_person_routing_rules(%Person{id: person_id}) do
    rules =
      Repo.all(
        from rule in IncomingMessageRoutingRule,
          where: rule.person_id == ^person_id
      )

    assert rules == []
  end
end
