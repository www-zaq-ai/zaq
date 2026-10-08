defmodule Zaq.Engine.History.MembershipOrder do
  @moduledoc """
  Provider-neutral ordering of complete membership snapshots and member events.
  Channels revisions must share one monotonically ordered room namespace.
  Unversioned snapshots remain supported until versioned evidence is observed;
  they can never overwrite it. Per-member fences preserve reordered events for
  different people. Targeted refreshes advance only their own member fences.
  """

  @doc "Applies a normalized member event to its durable ordering fence."
  def event(state, platform, member, operation, revision)
      when operation in [:add, :remove] and is_integer(revision) and revision >= 0 do
    with :ok <- same_platform(state, platform),
         :ok <- ordered_events?(state) do
      event_at(state, platform, member, operation, revision)
    end
  end

  def event(_, _, _, _, _), do: {:error, :invalid_membership_event}

  defp event_at(state, platform, member, operation, revision) do
    events = state["events"] || %{}
    floor = max(state["snapshot"] || -1, get_in(events, [member, "revision"]) || -1)

    if revision <= floor do
      {:ok, :stale, state}
    else
      entry = %{"revision" => revision, "present" => operation == :add}
      members = set_member(MapSet.new(state["members"] || []), member, entry["present"])

      {:ok, :applied,
       Map.merge(state, %{
         "platform" => platform,
         "events" => Map.put(events, member, entry),
         "members" => Enum.sort(members)
       })}
    end
  end

  defp ordered_events?(state) do
    if Map.has_key?(state, "members") and is_nil(state["snapshot"]) and
         map_size(state["events"] || %{}) == 0, do: {:error, :unordered_snapshot}, else: :ok
  end

  @doc "Combines a complete snapshot with newer member evidence without resurrecting revoked access."
  def snapshot(state, %{identity_platform: platform, member_ids: ids} = snapshot, targets) do
    with :ok <- same_platform(state, platform),
         :ok <- valid_revision(state, snapshot[:revision]) do
      snapshot_at(state, platform, ids, snapshot[:revision], targets)
    end
  end

  defp snapshot_at(state, platform, ids, nil, targets),
    do:
      {:ok, ids,
       Map.merge(snapshot_scope(state, targets), %{
         "platform" => platform,
         "members" => merged_members(state, ids, targets)
       })}

  defp snapshot_at(%{"snapshot" => revision} = state, _platform, _ids, revision, _targets),
    do: {:ok, state["members"] || [], state}

  defp snapshot_at(state, platform, ids, revision, targets) do
    events = state["events"] || %{}

    effective =
      Enum.reduce(events, MapSet.new(ids), fn {member, entry}, members ->
        if entry["revision"] >= revision do
          set_member(members, member, entry["present"])
        else
          members
        end
      end)

    state =
      case targets do
        :all ->
          remaining = Map.filter(events, fn {_, entry} -> entry["revision"] > revision end)

          Map.merge(state, %{
            "platform" => platform,
            "snapshot" => revision,
            "complete_snapshot" => true,
            "snapshot_targets" => [],
            "events" => remaining,
            "members" => Enum.sort(effective)
          })

        members ->
          entries =
            Enum.reduce(members, events, &put_member_fence(&2, &1, revision, effective))

          Map.merge(snapshot_scope(state, targets), %{
            "platform" => platform,
            "events" => entries,
            "members" => merged_members(state, effective, targets)
          })
      end

    {:ok, Enum.sort(effective), state}
  end

  defp snapshot_scope(state, :all),
    do: Map.merge(state, %{"complete_snapshot" => true, "snapshot_targets" => []})

  defp snapshot_scope(state, targets) do
    # Old unversioned states cannot distinguish full and targeted snapshots.
    # Retain their conservative authority; new states record the exact scope.
    legacy_complete =
      not is_nil(state["snapshot"]) or
        (Map.has_key?(state, "members") and map_size(state["events"] || %{}) == 0)

    state
    |> Map.put_new("complete_snapshot", legacy_complete)
    |> Map.put("snapshot_targets", Enum.uniq((state["snapshot_targets"] || []) ++ targets))
  end

  defp same_platform(state, platform) do
    if state["platform"] in [nil, platform], do: :ok, else: {:error, :invalid_snapshot}
  end

  defp set_member(members, member, true), do: MapSet.put(members, member)
  defp set_member(members, member, false), do: MapSet.delete(members, member)

  defp put_member_fence(events, member, revision, effective) do
    if (get_in(events, [member, "revision"]) || -1) >= revision do
      events
    else
      Map.put(events, member, %{
        "revision" => revision,
        "present" => MapSet.member?(effective, member)
      })
    end
  end

  defp valid_revision(state, nil) do
    if is_nil(state["snapshot"]) and map_size(state["events"] || %{}) == 0,
      do: :ok,
      else: {:error, :unordered_snapshot}
  end

  defp valid_revision(state, revision) when is_integer(revision) and revision >= 0 do
    if revision >= (state["snapshot"] || -1), do: :ok, else: {:error, :stale_snapshot}
  end

  defp valid_revision(_, _), do: {:error, :invalid_snapshot}

  defp merged_members(_state, members, :all), do: Enum.sort(members)

  defp merged_members(state, members, targets) do
    previous = MapSet.new(state["members"] || []) |> MapSet.difference(MapSet.new(targets))
    selected = MapSet.new(members) |> MapSet.intersection(MapSet.new(targets))
    previous |> MapSet.union(selected) |> Enum.sort()
  end
end
