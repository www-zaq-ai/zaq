defmodule Zaq.Engine.History.Direct do
  @moduledoc "One one-to-one history with explicit participant grants and no membership synchronization."
  @behaviour Zaq.Engine.History.Strategy

  alias Zaq.Engine.History.Strategy
  alias Zaq.Permissions.ChannelHistoryResource

  @impl true
  def association_targets(facts), do: [Strategy.grant_target(facts, "direct")]

  @impl true
  def resolve_transcripts(facts), do: association_targets(facts)

  @impl true
  def access_policy(facts) do
    resource =
      ChannelHistoryResource.for(facts.provider, facts.channel_config_id, facts.channel_id)

    participants =
      facts.recipient_person_ids
      |> Enum.concat([facts.actor_person_id])
      |> Enum.uniq()
      |> Enum.sort()

    [{:participant_grants, resource, participants}]
  end

  @impl true
  def context_sources(_facts), do: [:direct]

  @impl true
  def membership_lifecycle, do: :participant_grants
end
