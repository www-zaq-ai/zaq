defmodule Zaq.Engine.History.Replicated do
  @moduledoc "Message-local recipient copies. Never infer recipients from a thread's prior audience."
  @behaviour Zaq.Engine.History.Strategy

  alias Zaq.Engine.History.Strategy

  @impl true
  def association_targets(facts) do
    conversation_id = facts.conversation_id || facts.channel_id

    Enum.map(recipient_ids(facts), fn person_id ->
      %{
        strategy: "replicated",
        provider: facts.provider,
        channel_config_id: facts.channel_config_id,
        external_channel_id: conversation_id,
        external_thread_id: facts.conversation_id,
        parent_id: nil,
        owner_person_id: person_id,
        permission_resource_type: "person_history",
        permission_resource_id:
          Jason.encode!([facts.provider, facts.channel_config_id, conversation_id, person_id]),
        scope_key:
          Strategy.scope_key(%{facts | channel_id: conversation_id}, "replicated", person_id)
      }
    end)
  end

  @impl true
  def resolve_transcripts(facts),
    do: Enum.filter(association_targets(facts), &(&1.owner_person_id == facts.actor_person_id))

  @impl true
  def access_policy(facts), do: recipient_ids(facts)

  @impl true
  def context_sources(_facts), do: [:recipient]

  @impl true
  def membership_lifecycle, do: :none

  defp recipient_ids(facts),
    do:
      facts.recipient_person_ids
      |> Enum.concat([facts.actor_person_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
end
