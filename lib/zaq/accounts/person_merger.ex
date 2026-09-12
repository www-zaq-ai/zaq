defmodule Zaq.Accounts.PersonMerger do
  @moduledoc """
  Atomic consolidation of supplied persisted Person identities. Locks and snapshots
  the whole group, privately calculates its complete final state, and validates
  planned owner changesets before any write. Applies constraint-safe relationship
  mutations through their owners, deletes losers, then asks People to persist the
  complete survivor once. Any failure rolls back the transaction.

  IDs and history come only from persisted participants. Resource request editing
  belongs to People; workflow execution/audit JSON is never rewritten. No
  application processes are required.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Engine.{IncomingMessageRouting, IncomingMessageRoutingRule}
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Permissions
  alias Zaq.Permissions.ResourcePermission
  alias Zaq.Repo

  # Reserved two-key advisory lock namespace for ZAQ identity merges. Keep these
  # existing values stable so all callers coordinate on the same database lock.
  @identity_merge_lock_namespace 20_577
  @identity_merge_lock_key 1

  @doc """
  Runs an identity mutation atomically under the same lock as group merges.
  The reserved advisory lock pair {20577, 1} serializes participating identity
  mutations across connections to the same database, not across databases.
  PostgreSQL releases it when the enclosing transaction ends.
  """
  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @identity_merge_lock_namespace,
        @identity_merge_lock_key
      ])

      fun.()
    end)
  end

  @doc "Implements the canonical group transaction behind People.merge_persons/3."
  @spec merge(Person.t() | integer(), Person.t() | integer() | list(), keyword()) ::
          {:ok, Person.t()} | {:error, term()}
  def merge(survivor, losers, opts) do
    transaction(fn ->
      {survivor, losers} = locked_people(survivor, losers)
      people = [survivor | losers]
      ids = Enum.map(people, & &1.id)

      channels =
        Repo.all(
          from c in PersonChannel,
            where: c.person_id in ^ids,
            order_by: c.id,
            lock: "FOR UPDATE"
        )
        |> Enum.sort_by(&{&1.weight, &1.id})

      relations = locked_relations(ids, Enum.map(losers, & &1.id))

      {aliases, history} =
        identity_history(people, channels, Keyword.get(opts, :retain_redirect, true))

      attrs =
        profile(people, channels)
        |> Map.merge(%{merged_person_ids: aliases, merge_history: history})

      channel_results = channel_results(survivor.id, channels)
      email_channel = email_channel(survivor, attrs, channel_results)
      grants = permission_results(survivor.id, ids, relations.permissions)
      rules = routing_results(survivor.id, relations.rules)
      links = link_results(survivor.id, relations)

      validate_result!(
        attrs,
        channel_results,
        email_channel,
        grants,
        rules,
        links
      )

      apply_channels(channel_results, email_channel)
      apply_permissions(relations.permissions, grants, opts)
      apply_routing(rules)
      transfer_links(links)
      # All losers must disappear BEFORE canonical email is written (three-way
      # collision) and before their inherited aliases are installed on survivor.
      Enum.each(losers, &(People.delete_person(&1) |> result!()))

      People.apply_merge_result(survivor, attrs)
      |> result!()
      |> then(&People.get_person_with_channels!(&1.id))
    end)
  end

  defp locked_people(survivor, losers) do
    survivor = person!(survivor)

    losers =
      losers
      |> List.wrap()
      |> Enum.map(&person!/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)

    if Enum.any?(losers, &(&1.id == survivor.id)), do: Repo.rollback(:self_merge)
    ids = Enum.map([survivor | losers], & &1.id)
    rows = Repo.all(from p in Person, where: p.id in ^ids, order_by: p.id, lock: "FOR UPDATE")
    by_id = Map.new(rows, &{&1.id, &1})
    {Map.fetch!(by_id, survivor.id), Enum.map(losers, &Map.fetch!(by_id, &1.id))}
  end

  defp person!(%Person{id: id}), do: person!(id)
  defp person!(id), do: People.get_person(id) || Repo.rollback(:not_found)
  defp result!({:ok, value}), do: value
  defp result!({:error, reason}), do: Repo.rollback(reason)

  defp profile([survivor | _] = people, channels) do
    identifiers = Enum.map(channels, & &1.channel_identifier)

    Enum.reduce(people, %{}, fn person, acc ->
      fields = Map.take(person, [:full_name, :email, :phone, :role, :status, :metadata])

      fields =
        if person.full_name in identifiers, do: Map.put(fields, :full_name, nil), else: fields

      fill_missing(acc, fields)
    end)
    |> Map.update!(:full_name, &(&1 || survivor.full_name))
    |> Map.update!(:email, &Person.normalize_email/1)
    |> Map.put(:team_ids, people |> Enum.flat_map(&(&1.team_ids || [])) |> Enum.uniq())
  end

  defp fill_missing(first, other) when is_map(first) and is_map(other),
    do: Map.merge(first, other, fn _key, left, right -> fill_missing(left, right) end)

  defp fill_missing(first, other), do: if(blank?(first), do: other, else: first)
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp identity_history([survivor | losers] = people, channels, retain?) do
    aliases = Enum.flat_map(people, & &1.merged_person_ids)
    aliases = if retain?, do: aliases ++ Enum.map(losers, & &1.id), else: aliases
    history = Enum.flat_map(people, & &1.merge_history)
    timestamp = DateTime.utc_now(:second) |> DateTime.to_iso8601()

    entries =
      if retain?,
        do:
          Enum.map(
            losers,
            &%{"id" => &1.id, "label" => label(&1, channels), "merged_at" => timestamp}
          ),
        else: []

    aliases = aliases |> Enum.reject(&(&1 == survivor.id)) |> Enum.uniq() |> Enum.sort()

    {aliases,
     (history ++ entries)
     |> Enum.uniq_by(& &1["id"])
     |> Enum.sort_by(&{&1["merged_at"], &1["id"]})}
  end

  defp label(person, channels) do
    if blank?(person.full_name) do
      case Enum.find(channels, &(&1.person_id == person.id)) do
        nil -> "Person ##{person.id}"
        channel -> channel.channel_identifier
      end
    else
      person.full_name
    end
  end

  defp channel_results(survivor_id, channels) do
    channels
    |> Enum.sort_by(&{&1.person_id != survivor_id, &1.person_id, &1.id})
    |> Enum.group_by(
      &{&1.platform, PersonChannel.normalize_identifier(&1.platform, &1.channel_identifier)}
    )
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, [first | rest] = group} ->
      attrs =
        channel_attributes(group)
        |> Map.put(:person_id, survivor_id)
        |> Map.put(:weight, first.weight)
        |> Map.put(:platform, first.platform)

      {first, attrs, rest}
    end)
  end

  defp channel_attributes([first | rest] = group) do
    fields = [:username, :display_name, :phone, :dm_channel_id, :metadata]

    latest =
      group
      |> Enum.map(& &1.last_interaction_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    Enum.reduce(rest, Map.take(first, fields), &fill_missing(&2, Map.take(&1, fields)))
    |> Map.put(
      :channel_identifier,
      PersonChannel.normalize_identifier(first.platform, first.channel_identifier)
    )
    |> Map.put(:last_interaction_at, latest)
  end

  defp locked_relations(ids, losers) do
    resource_ids = Enum.map(ids, &to_string/1)

    %{
      permissions:
        Repo.all(
          from p in ResourcePermission,
            where:
              p.person_id in ^ids or
                (p.resource_type == "person" and p.resource_id in ^resource_ids),
            order_by: p.id,
            lock: "FOR UPDATE"
        ),
      rules:
        Repo.all(
          from r in IncomingMessageRoutingRule,
            where: r.person_id in ^ids,
            order_by: r.id,
            lock: "FOR UPDATE"
        ),
      conversations:
        Repo.all(
          from c in Conversation,
            where: c.person_id in ^losers,
            order_by: c.id,
            lock: "FOR UPDATE"
        ),
      notifications:
        Repo.all(
          from l in NotificationLog,
            where: l.recipient_ref_type == "person" and l.recipient_ref_id in ^losers,
            order_by: l.id,
            lock: "FOR UPDATE"
        )
    }
  end

  defp permission_results(survivor_id, ids, originals) do
    resource_ids = Enum.map(ids, &to_string/1)

    originals
    |> Enum.flat_map(&split_team_grant/1)
    |> Enum.group_by(&permission_key(&1, survivor_id, ids, resource_ids))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{type, resource_id, kind, principal_id}, group} ->
      rights = group |> Enum.flat_map(& &1.access_rights) |> Enum.uniq() |> Enum.sort()
      {{type, resource_id}, %{kind => principal_id, :access_rights => rights}}
    end)
  end

  defp apply_permissions(originals, grants, opts) do
    Enum.each(originals, fn permission ->
      case Permissions.revoke(
             {permission.resource_type, permission.resource_id},
             permission,
             opts
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    Enum.each(grants, fn {resource, attrs} ->
      Permissions.grant(resource, attrs) |> result!()
    end)
  end

  defp split_team_grant(%{team_id: nil} = permission), do: [permission]
  defp split_team_grant(%{person_id: nil} = permission), do: [permission]

  defp split_team_grant(permission),
    do: [%{permission | team_id: nil}, %{permission | person_id: nil}]

  defp permission_key(permission, survivor, ids, resource_ids) do
    person_id = if permission.person_id in ids, do: survivor, else: permission.person_id

    resource_id =
      if permission.resource_type == "person" and permission.resource_id in resource_ids,
        do: to_string(survivor),
        else: permission.resource_id

    {kind, principal_id} =
      if person_id, do: {:person_id, person_id}, else: {:team_id, permission.team_id}

    {permission.resource_type, resource_id, kind, principal_id}
  end

  defp routing_results(survivor_id, rules) do
    rules
    |> Enum.sort_by(&{&1.person_id != survivor_id, &1.person_id, &1.id})
    |> Enum.group_by(&routing_key/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, [first | rest]} -> {first, %{person_id: survivor_id}, rest} end)
  end

  defp apply_routing(rules) do
    Enum.each(rules, fn {first, attrs, rest} ->
      Enum.each(
        rest,
        &(IncomingMessageRouting.delete_rule(
            Map.take(&1, [:person_id, :channel_config_id, :retrieval_channel_id, :topic_id])
          )
          |> result!())
      )

      IncomingMessageRouting.upsert_rule(first, attrs) |> result!()
    end)
  end

  defp routing_key(%{retrieval_channel_id: channel, topic_id: nil}) when not is_nil(channel),
    do: {:channel, channel}

  defp routing_key(rule), do: {rule.channel_config_id, rule.retrieval_channel_id, rule.topic_id}

  defp link_results(survivor_id, relations) do
    %{
      conversations: Enum.map(relations.conversations, &{&1, %{person_id: survivor_id}}),
      notifications: Enum.map(relations.notifications, &{&1, {:person, survivor_id}})
    }
  end

  defp transfer_links(links) do
    Enum.each(links.conversations, fn {row, attrs} ->
      Conversations.update_conversation(row, attrs) |> result!()
    end)

    Enum.each(links.notifications, fn {row, reference} ->
      NotificationLog.update_recipient(row, reference) |> result!()
    end)
  end

  defp email_channel(survivor, attrs, channels) do
    existing? =
      Enum.any?(channels, fn {_row, channel, _rest} ->
        channel.platform == "email" and channel.channel_identifier == attrs.email
      end)

    if attrs.email && attrs.email != survivor.email && not existing? do
      weight =
        channels |> Enum.map(fn {_, channel, _} -> channel.weight end) |> Enum.max(fn -> -1 end)

      %{
        person_id: survivor.id,
        platform: "email",
        channel_identifier: attrs.email,
        display_name: attrs.full_name,
        weight: weight + 1
      }
    end
  end

  defp validate_result!(attrs, channels, email, grants, rules, links) do
    # Fresh schema values make Ecto field validators inspect the entire final
    # state, including invalid legacy values unchanged on a loaded record.
    Person.merge_result_changeset(%Person{}, attrs) |> valid!()

    Enum.each(channels, fn {_row, attrs, _rest} ->
      PersonChannel.changeset(%PersonChannel{}, attrs) |> valid!()
    end)

    if email, do: PersonChannel.changeset(%PersonChannel{}, email) |> valid!()

    Enum.each(grants, fn {{type, id}, attrs} ->
      ResourcePermission.changeset(
        %ResourcePermission{},
        Map.merge(attrs, %{resource_type: type, resource_id: id})
      )
      |> valid!()
    end)

    Enum.each(rules, fn {row, attrs, rest} ->
      IncomingMessageRouting.change_rule(row, attrs) |> valid!()
      # Discarded rows retain structural validation, but their old database-backed
      # destination policies are not part of the final routing state.
      Enum.each(rest, &(IncomingMessageRoutingRule.changeset(&1, %{}) |> valid!()))
    end)

    Enum.each(links.conversations, fn {row, attrs} ->
      fields =
        Map.take(row, [
          :title,
          :user_id,
          :channel_user_id,
          :channel_type,
          :channel_config_id,
          :status,
          :metadata
        ])

      Conversation.changeset(%Conversation{}, Map.merge(fields, attrs))
      |> valid!()
    end)

    Enum.each(links.notifications, fn {row, reference} ->
      NotificationLog.change_recipient(row, reference) |> result!() |> valid!()
    end)
  end

  defp valid!(%Changeset{valid?: true}), do: :ok
  defp valid!(changeset), do: Repo.rollback(changeset)

  defp apply_channels(channels, email) do
    Enum.each(channels, fn {row, attrs, rest} ->
      Enum.each(rest, &(People.delete_channel(&1) |> result!()))
      People.apply_channel_merge_result(row, attrs) |> result!()
    end)

    if email, do: People.add_channel(email) |> result!()
  end
end
