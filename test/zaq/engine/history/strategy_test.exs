defmodule Zaq.Engine.History.StrategyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Conversations.Transcript
  alias Zaq.Engine.History.{Facts, Strategy}
  alias Zaq.Permissions.ChannelHistoryResource

  defp facts(overrides \\ %{}) do
    attrs = %{
      provider: "mattermost",
      channel_config_id: 12,
      channel_id: "room-1",
      kind: :channel,
      actor_person_id: 5
    }

    Facts.new(Map.merge(attrs, overrides))
  end

  defp parent(strategy, overrides \\ %{}) do
    {type, id} = ChannelHistoryResource.for("mattermost", 12, "room-1")

    struct!(
      Transcript,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          provider: "mattermost",
          channel_config_id: 12,
          external_channel_id: "room-1",
          strategy: strategy,
          permission_resource_type: type,
          permission_resource_id: id
        },
        overrides
      )
    )
  end

  test "Direct uses one conversation transcript and participant grants, even in a thread" do
    assert {:ok, direct} = facts(%{kind: :direct})
    assert {:ok, [{:participant_grants, resource, [5]}]} = Strategy.access_policy(direct)
    assert resource == ChannelHistoryResource.for("mattermost", 12, "room-1")
    assert {:ok, [target]} = Strategy.association_targets(direct)
    assert {:ok, [^target]} = Strategy.resolve_transcripts(direct)
    assert target.strategy == "direct"
    assert target.owner_person_id == nil
    assert target.parent_id == nil
    assert target.permission_resource_id == elem(resource, 1)
    assert {:ok, :participant_grants} = Strategy.membership_lifecycle(direct)
    assert {:ok, [:direct]} = Strategy.context_sources(direct)

    assert {:ok, participants} = facts(%{kind: :direct, recipient_person_ids: [9, 5, 8, 9]})

    assert {:ok, [{:participant_grants, ^resource, [5, 8, 9]}]} =
             Strategy.access_policy(participants)

    assert {:ok, threaded} =
             facts(%{kind: :direct, thread_id: "reply-1", parent: parent("direct")})

    assert {:ok, [thread_target]} = Strategy.association_targets(threaded)
    assert thread_target.scope_key == target.scope_key
    assert thread_target.external_thread_id == nil
  end

  test "Shared main and thread transcripts inherit channel grants but not each other's history" do
    assert {:ok, main} = facts()
    assert {:ok, [root_target]} = Strategy.association_targets(main)
    assert root_target.strategy == "shared"
    assert root_target.parent_id == nil
    assert {:ok, [:main]} = Strategy.context_sources(main)
    assert {:ok, :provider_grants} = Strategy.membership_lifecycle(main)

    root = parent("shared")
    assert {:ok, thread} = facts(%{thread_id: "thread-1", parent: root})
    assert {:ok, [thread_target]} = Strategy.association_targets(thread)
    assert {:ok, [^thread_target]} = Strategy.resolve_transcripts(thread)
    assert thread_target.parent_id == root.id
    assert thread_target.external_thread_id == "thread-1"
    assert thread_target.scope_key != root_target.scope_key
    assert thread_target.permission_resource_id == root_target.permission_resource_id

    assert {:ok, [:thread_root, :thread_local, :bounded_parent]} =
             Strategy.context_sources(thread)

    assert {:ok, [{:grant, resource}]} = Strategy.access_policy(thread)
    assert resource == ChannelHistoryResource.for("mattermost", 12, "room-1")

    assert {:error, :missing_parent} = facts(%{thread_id: "thread-1"})
    assert {:error, :unexpected_parent} = facts(%{parent: root})
  end

  test "thread parent must be same provider, connector, channel and inherited strategy" do
    for mismatch <- [
          %{strategy: "direct"},
          %{provider: "slack"},
          %{channel_config_id: 13},
          %{external_channel_id: "room-2"},
          %{permission_resource_id: "forged"},
          %{parent_id: Ecto.UUID.generate()}
        ] do
      assert {:error, :parent_scope_mismatch} =
               facts(%{thread_id: "thread-1", parent: parent("shared", mismatch)})
    end
  end

  test "transcript scopes and grants cannot collide across connectors or providers" do
    assert {:ok, original} = facts(%{kind: :direct})
    assert {:ok, second_connector} = facts(%{kind: :direct, channel_config_id: 13})
    assert {:ok, second_provider} = facts(%{kind: :direct, provider: "slack"})

    scopes =
      for input <- [original, second_connector, second_provider] do
        assert {:ok, [target]} = Strategy.association_targets(input)
        {target.scope_key, target.permission_resource_id}
      end

    assert Enum.uniq(scopes) == scopes
  end

  test "Replicated targets only the sender and evidenced recipients of this message" do
    assert {:ok, mail} =
             facts(%{
               provider: "email:imap",
               kind: :email,
               channel_id: "conversation-1",
               actor_person_id: 5,
               recipient_person_ids: [8, 5, 7, 8]
             })

    assert {:ok, targets} = Strategy.association_targets(mail)
    assert {:ok, [request_owner]} = Strategy.resolve_transcripts(mail)
    assert request_owner.owner_person_id == 5
    assert Enum.map(targets, & &1.owner_person_id) == [5, 7, 8]
    assert Enum.uniq(Enum.map(targets, & &1.scope_key)) == Enum.map(targets, & &1.scope_key)
    assert Enum.all?(targets, &(&1.strategy == "replicated"))
    assert {:ok, [5, 7, 8]} = Strategy.access_policy(mail)
    assert {:ok, :none} = Strategy.membership_lifecycle(mail)
    assert {:ok, [:recipient]} = Strategy.context_sources(mail)

    assert {:ok, next_mail} =
             facts(%{
               provider: "email:imap",
               kind: :email,
               channel_id: "conversation-1",
               actor_person_id: 5,
               recipient_person_ids: [9]
             })

    assert {:ok, next_targets} = Strategy.association_targets(next_mail)
    assert Enum.map(next_targets, & &1.owner_person_id) == [5, 9]
    refute Enum.any?(next_targets, &(&1.owner_person_id == 8))
  end

  test "provider defaults and unsupported provider/kind combinations fail closed" do
    for provider <- ~w(mattermost slack discord teams telegram), kind <- [:direct, :channel] do
      assert {:ok, candidate} = facts(%{provider: provider, kind: kind})
      assert {:ok, [_]} = Strategy.association_targets(candidate)
    end

    for overrides <- [
          %{provider: "email:imap", kind: :channel},
          %{provider: "mattermost", kind: :email},
          %{provider: "email:smtp", kind: :email},
          %{provider: "google_drive", kind: :channel},
          %{provider: "bo", kind: :direct},
          %{provider: "api", kind: :direct},
          %{kind: :unknown}
        ] do
      assert {:error, :unsupported_strategy} = facts(overrides)
    end

    for overrides <- [
          %{channel_config_id: nil},
          %{channel_config_id: 0},
          %{channel_id: ""},
          %{channel_id: "  "},
          %{channel_id: nil},
          %{actor_person_id: nil},
          %{actor_person_id: 0}
        ] do
      assert {:error, :invalid_history_facts} = facts(overrides)
    end
  end

  property "recipient permutations never change a replicated target set or reveal a prior recipient" do
    check all(recipients <- uniq_list_of(integer(1..30), max_length: 15), max_runs: 60) do
      assert {:ok, mail} =
               facts(%{
                 provider: "email:imap",
                 kind: :email,
                 channel_id: "mail-thread",
                 recipient_person_ids: recipients
               })

      assert {:ok, targets} = Strategy.association_targets(mail)
      assert Enum.map(targets, & &1.owner_person_id) == Enum.sort(Enum.uniq([5 | recipients]))
      assert Enum.all?(targets, &(&1.channel_config_id == 12))
    end
  end
end
