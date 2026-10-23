defmodule Zaq.Engine.History.Direct do
  @moduledoc "One-to-one main and thread histories sharing explicit participant grants, without membership synchronization."
  @behaviour Zaq.Engine.History.Strategy

  alias Zaq.Engine.History.Strategy
  alias Zaq.Permissions.ChannelHistoryResource

  @impl true
  def association_targets(facts), do: [Strategy.grant_target(facts, "direct", facts.thread_id)]

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
  def context_sources(%{thread_id: nil}), do: [:direct]

  def context_sources(_thread), do: [:thread_root, :thread_local, :bounded_parent]

  @impl true
  def membership_lifecycle, do: :participant_grants
end
