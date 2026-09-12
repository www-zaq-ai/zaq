defmodule Zaq.Repo.Migrations.NormalizePersonEmails do
  use Ecto.Migration

  import Ecto.Query
  alias Zaq.Accounts.{People, Person, PersonChannel, PersonMerger}
  alias Zaq.Repo

  def up do
    # Intentional application-code data migration. Runs Repo-only, after the
    # alias schema migration, with all application writers quiesced.
    execute(fn ->
      # Acquire the shared identity lock before the table lock, matching the
      # merger's lock ordering. The migrator's default transaction also owns
      # the version ledger; any nested merge rollback must abort that transaction.
      case PersonMerger.transaction(&normalize_people/0) do
        {:ok, :ok} ->
          :ok

        {:error, reason} ->
          raise Ecto.MigrationError,
            message: "Person email normalization failed: #{inspect(reason)}"
      end
    end)

    # Execute cleanup before queuing the replacement index. Both data and DDL
    # remain inside the migrator's transaction, including its version ledger.
    flush()
    drop_if_exists unique_index(:channels, [:person_id, :platform, :channel_identifier])
    create unique_index(:channels, [:platform, :channel_identifier])
  end

  defp normalize_people do
    Repo.query!("LOCK TABLE people, channels IN SHARE ROW EXCLUSIVE MODE")
    people = Repo.all(from(p in Person, order_by: p.id, select: {p.id, p.email}))

    channels =
      Repo.all(
        from(c in PersonChannel, select: {c.id, c.person_id, c.platform, c.channel_identifier})
      )

    keys =
      Enum.flat_map(people, fn {id, email} ->
        case Person.normalize_email(email) do
          nil -> []
          email -> [{id, {"email", email}}]
        end
      end)

    keys =
      Enum.reduce(channels, keys, fn {id, person_id, platform, identifier}, acc ->
        if is_nil(identifier) or String.trim(identifier) == "" do
          raise Ecto.MigrationError,
            message:
              "Person email normalization failed: blank channel identifier at channel #{id}"
        end

        [{person_id, {platform, PersonChannel.normalize_identifier(platform, identifier)}} | acc]
      end)

    # Each key contributes a star, not all pairwise edges. Traversal visits each
    # Person once, so transitive cross-field identities form one complete group.
    {_, graph} =
      Enum.reduce(keys, {%{}, %{}}, fn {id, key}, {owners, graph} ->
        case Map.fetch(owners, key) do
          :error ->
            {Map.put(owners, key, id), graph}

          {:ok, ^id} ->
            {owners, graph}

          {:ok, owner} ->
            graph =
              graph
              |> Map.update(id, [owner], &[owner | &1])
              |> Map.update(owner, [id], &[id | &1])

            {owners, graph}
        end
      end)

    original_emails = Map.new(people)

    Enum.reduce(people, {MapSet.new(), []}, fn {id, _}, {visited, groups} ->
      if MapSet.member?(visited, id) do
        {visited, groups}
      else
        {visited, group} = connected([id], graph, visited, [])
        {visited, [Enum.sort(group) | groups]}
      end
    end)
    |> elem(1)
    |> Enum.sort_by(&hd/1)
    |> Enum.each(&normalize_group(&1, original_emails))
  end

  defp connected([], _graph, visited, group), do: {visited, group}

  defp connected([id | pending], graph, visited, group) do
    if MapSet.member?(visited, id) do
      connected(pending, graph, visited, group)
    else
      connected(Map.get(graph, id, []) ++ pending, graph, MapSet.put(visited, id), [id | group])
    end
  end

  defp normalize_group([id], _original_emails) do
    Repo.all(from(c in PersonChannel, where: c.person_id == ^id, order_by: c.id))
    |> Enum.group_by(
      &{&1.platform, PersonChannel.normalize_identifier(&1.platform, &1.channel_identifier)}
    )
    |> Enum.each(fn {_key, [first | rest] = group} ->
      Enum.each(rest, &(People.delete_channel(&1) |> applied!()))
      People.update_channel(first, singleton_channel_attributes(group)) |> applied!()
    end)

    person = People.get_person!(id)
    email = Person.normalize_email(person.email)

    if email != person.email do
      person |> People.update_person(%{email: email}) |> applied!()
    end
  end

  defp normalize_group([survivor | losers] = ids, original_emails) do
    # Profile precedence retains only one email. Preserve every original identity
    # after consolidation, when canonical duplicates have already been removed.
    emails =
      ids
      |> Enum.map(&Person.normalize_email(Map.fetch!(original_emails, &1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    merged = People.merge_persons(survivor, losers, []) |> applied!()

    existing =
      for channel <- merged.channels,
          channel.platform == "email",
          into: MapSet.new(),
          do: channel.channel_identifier

    emails
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.each(fn email ->
      People.add_channel(%{person_id: merged.id, platform: "email", channel_identifier: email})
      |> applied!()
    end)
  end

  defp applied!({:ok, result}), do: result
  defp applied!({:error, reason}), do: Repo.rollback(reason)

  # Singleton cleanup has no Person merge. Fold only its legacy duplicate channel
  # attributes here; complete multi-person reconciliation stays with PersonMerger.
  defp singleton_channel_attributes([first | rest] = group) do
    fields = [:username, :display_name, :phone, :dm_channel_id, :metadata]

    latest =
      group
      |> Enum.map(& &1.last_interaction_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    Enum.reduce(rest, Map.take(first, fields), &fill_channel_blanks(&2, Map.take(&1, fields)))
    |> Map.put(
      :channel_identifier,
      PersonChannel.normalize_identifier(first.platform, first.channel_identifier)
    )
    |> Map.put(:last_interaction_at, latest)
  end

  defp fill_channel_blanks(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right, fn _, first, other -> fill_channel_blanks(first, other) end)

  defp fill_channel_blanks(nil, right), do: right

  defp fill_channel_blanks(left, right) when is_binary(left),
    do: if(String.trim(left) == "", do: right, else: left)

  defp fill_channel_blanks(left, _right), do: left

  def down,
    do:
      raise(Ecto.MigrationError,
        message: "Person merges are irreversible; restore the pre-migration backup"
      )
end
