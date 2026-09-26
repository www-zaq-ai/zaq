defmodule Zaq.Engine.History.Shared do
  @moduledoc "Shared main-channel history with local thread history and inherited channel grants."
  @behaviour Zaq.Engine.History.Strategy

  alias Zaq.Engine.History.Strategy
  alias Zaq.Permissions.ChannelHistoryResource

  @impl true
  def association_targets(facts), do: [Strategy.grant_target(facts, "shared", facts.thread_id)]

  @impl true
  def resolve_transcripts(facts), do: association_targets(facts)

  @impl true
  def access_policy(facts),
    do: [
      {:grant,
       ChannelHistoryResource.for(facts.provider, facts.channel_config_id, facts.channel_id)}
    ]

  @impl true
  def context_sources(%{thread_id: nil}), do: [:main]
  def context_sources(_thread), do: [:thread_root, :thread_local, :bounded_parent]

  @impl true
  def membership_lifecycle, do: :provider_grants
end
