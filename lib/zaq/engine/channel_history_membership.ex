defmodule Zaq.Engine.ChannelHistoryMembership do
  @moduledoc """
  Reconciles one Shared room's provider-derived read grants from a complete
  connector snapshot. The Engine serializes refreshes before fetching the
  provider, so a delayed older fetch cannot overwrite a newer refresh. Missing,
  partial or malformed provider results never revoke access. Manual grants are
  independent and are never changed here.
  """

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations.Transcript
  alias Zaq.Engine.History.MembershipOrder
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Permissions
  alias Zaq.Repo

  import Ecto.Query

  @max_members 10_000

  @doc "Refreshes a Shared room using a complete normalized Channels snapshot."
  @spec refresh(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh(transcript_id, opts \\ []) when is_list(opts) do
    router = Keyword.get(opts, :router, NodeRouter)

    case Ecto.UUID.cast(transcript_id) do
      {:ok, id} -> Repo.transaction(fn -> refresh_locked(id, router) end)
      :error -> {:error, :not_found}
    end
  end

  @doc "Refreshes only one Person's access to existing Shared rooms on the selected connector."
  def refresh_person(person_id, config_id, opts \\ [])
      when is_integer(person_id) and person_id > 0 and is_integer(config_id) and config_id > 0 do
    router = Keyword.get(opts, :router, NodeRouter)

    Repo.transaction(fn ->
      unless match?(%Person{status: "active"}, Repo.get(Person, person_id)),
        do: Repo.rollback(:invalid_person)

      ids =
        Repo.all(
          from t in Transcript,
            where:
              t.channel_config_id == ^config_id and
                t.strategy == "shared" and is_nil(t.parent_id),
            order_by: t.id,
            select: t.id
        )

      if ids == [], do: Repo.rollback(:unsupported_membership_refresh)
      results = Enum.map(ids, &refresh_locked(&1, router, person_id))
      %{rooms: length(results), members: Enum.sum(Enum.map(results, & &1.members))}
    end)
  end

  @doc "Applies internally trusted normalized membership evidence; never accepts provider payloads."
  def apply_event(
        %{
          provider: provider,
          channel_config_id: config_id,
          channel_id: channel_id,
          identity_platform: platform,
          member_id: member,
          operation: _operation,
          revision: _revision
        } = event
      )
      when is_binary(provider) and is_integer(config_id) and config_id > 0 and
             is_binary(channel_id) and is_binary(platform) and byte_size(platform) in 1..255 and
             is_binary(member) and byte_size(member) in 1..255 do
    Repo.transaction(fn -> apply_event_locked(event) end)
  end

  def apply_event(_), do: {:error, :invalid_membership_event}

  defp apply_event_locked(%{
         provider: provider,
         channel_config_id: config_id,
         channel_id: channel_id,
         identity_platform: platform,
         member_id: member,
         operation: operation,
         revision: revision
       }) do
    transcript =
      Repo.one(
        from t in Transcript,
          where:
            t.provider == ^provider and
              t.channel_config_id == ^config_id and t.external_channel_id == ^channel_id and
              t.strategy == "shared" and is_nil(t.parent_id)
      )

    unless transcript, do: Repo.rollback(:unsupported_membership_refresh)
    {root, resource} = locked_root(transcript)

    case MembershipOrder.event(root.membership_state, platform, member, operation, revision) do
      {:ok, :stale, _} ->
        %{status: :stale}

      {:ok, :applied, state} ->
        apply_member(root, resource, platform, member, state)
        store_state(root, state)
        %{status: :applied}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp refresh_locked(id, router, person_id \\ nil) do
    with %Transcript{strategy: "shared", provider: provider} = transcript <-
           Repo.get(Transcript, id),
         %ChannelConfig{provider: ^provider, enabled: true, archived_at: nil} <-
           Repo.get(ChannelConfig, transcript.channel_config_id) do
      {root, resource} = locked_root(transcript)

      request = %{
        channel_config_id: transcript.channel_config_id,
        channel_id: transcript.external_channel_id
      }

      event = Event.new(request, :channels, opts: [action: :channel_history_membership_snapshot])

      with %Event{
             response:
               {:ok, %{complete: true, member_ids: ids, identity_platform: platform} = snapshot}
           } <-
             router.dispatch(event),
           true <- is_binary(platform) and byte_size(platform) in 1..255,
           :ok <- valid_members?(ids),
           {:ok, targets} <- target_identifiers(person_id, transcript.channel_config_id, platform),
           {:ok, effective, state} <-
             MembershipOrder.snapshot(root.membership_state, snapshot, targets),
           {:ok, person_ids} <- resolved_people(transcript.channel_config_id, platform, effective),
           person_ids = Enum.filter(person_ids, &(is_nil(person_id) or &1 == person_id)),
           :ok <-
             reconcile(resource, person_ids, "channel_history:provider:" <> provider, person_id) do
        store_state(root, state)
        %{members: length(person_ids)}
      else
        %Event{response: {:error, reason}} -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_snapshot)
      end
    else
      _ -> Repo.rollback(:unsupported_membership_refresh)
    end
  end

  defp valid_members?(ids) when is_list(ids) and length(ids) <= @max_members do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..255)),
      do: :ok,
      else: {:error, :invalid_snapshot}
  end

  defp valid_members?(_), do: {:error, :invalid_snapshot}

  defp resolved_people(config_id, platform, ids) do
    people =
      ids
      |> Enum.uniq()
      |> Enum.flat_map(fn id ->
        case People.match_by_channel(platform, id, config_id) do
          {:ok, %{id: person_id, status: "active"}} -> [person_id]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, people}
  end

  defp reconcile(resource, person_ids, source_key, target_person) do
    existing =
      resource
      |> Permissions.list_direct()
      |> Enum.filter(
        &(&1.source_key == source_key and is_integer(&1.person_id) and
            (is_nil(target_person) or &1.person_id == target_person))
      )

    requested = MapSet.new(person_ids)

    Enum.each(existing, &revoke_missing(resource, &1, requested))

    Enum.each(person_ids, fn person_id ->
      case Permissions.grant(resource, %{
             person_id: person_id,
             source_key: source_key,
             access_rights: ["read"]
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    :ok
  end

  defp revoke_missing(resource, permission, requested) do
    unless MapSet.member?(requested, permission.person_id) do
      case Permissions.revoke(resource, permission) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp locked_root(transcript) do
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["channel_history:membership", elem(resource, 0), elem(resource, 1)])
    ])

    provider = transcript.provider

    unless match?(
             %ChannelConfig{provider: ^provider, enabled: true, archived_at: nil},
             Repo.get(ChannelConfig, transcript.channel_config_id)
           ),
           do: Repo.rollback(:unsupported_membership_refresh)

    root =
      Repo.one!(
        from t in Transcript,
          where:
            t.permission_resource_type == ^elem(resource, 0) and
              t.permission_resource_id == ^elem(resource, 1) and t.strategy == "shared" and
              is_nil(t.parent_id)
      )

    {root, resource}
  end

  defp target_identifiers(nil, _config, _platform), do: {:ok, :all}

  defp target_identifiers(person_id, config_id, platform) do
    ids =
      People.list_person_channels(person_id)
      |> Enum.filter(&(&1.channel_config_id == config_id and &1.platform == platform))
      |> Enum.map(& &1.channel_identifier)

    if ids == [], do: {:error, :unlinked_member}, else: {:ok, ids}
  end

  defp apply_member(root, resource, platform, member, state) do
    case People.match_by_channel(platform, member, root.channel_config_id) do
      {:ok, %{id: person_id}} ->
        {:ok, members} = resolved_people(root.channel_config_id, platform, state["members"] || [])
        ids = Enum.filter(members, &(&1 == person_id))
        reconcile(resource, ids, "channel_history:provider:" <> root.provider, person_id)

      _ ->
        :ok
    end
  end

  defp store_state(root, state) do
    root |> Ecto.Changeset.change(membership_state: state) |> Repo.update!()
  end
end
