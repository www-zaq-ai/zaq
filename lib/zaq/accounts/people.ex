defmodule Zaq.Accounts.People do
  @moduledoc """
  Context for managing people, their communication channels, and teams.
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Accounts.Team
  alias Zaq.Repo

  # ── People ──────────────────────────────────────────────────────────────

  def list_people do
    people = Repo.all(from p in Person, order_by: p.full_name)
    Repo.preload(people, channels: channels_ordered())
  end

  @doc "Returns all people with incomplete: true."
  @spec list_incomplete() :: [Person.t()]
  def list_incomplete do
    Repo.all(from p in Person, where: p.incomplete == true, order_by: p.inserted_at)
    |> Repo.preload(channels: channels_ordered())
  end

  @doc "Filters people by name, email, phone, completeness, and team membership. Returns `{people, total_count}`."
  @spec filter_people(map(), keyword()) :: {[Person.t()], non_neg_integer()}
  def filter_people(filters, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    base = build_filter_query(filters)
    total = Repo.aggregate(base, :count)

    people =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Repo.preload(channels: channels_ordered())

    {people, total}
  end

  defp build_filter_query(filters) do
    name = Map.get(filters, "name", "")
    email = Map.get(filters, "email", "")
    phone = Map.get(filters, "phone", "")
    complete = Map.get(filters, "complete", "all")
    team_id = Map.get(filters, "team_id", "")

    query = from(p in Person, order_by: p.full_name)

    query =
      if name != "",
        do: from(p in query, where: ilike(p.full_name, ^"%#{escape_like(name)}%")),
        else: query

    query =
      if email != "",
        do: from(p in query, where: ilike(p.email, ^"%#{escape_like(email)}%")),
        else: query

    query =
      if phone != "",
        do: from(p in query, where: ilike(p.phone, ^"%#{escape_like(phone)}%")),
        else: query

    query =
      case complete do
        "complete" -> from(p in query, where: p.incomplete == false)
        "incomplete" -> from(p in query, where: p.incomplete == true)
        _ -> query
      end

    if team_id != "" do
      team_id_int = String.to_integer(team_id)
      from(p in query, where: ^team_id_int in p.team_ids)
    else
      query
    end
  end

  @doc "Matches a person by platform and channel identifier directly."
  @spec match_by_channel(String.t(), String.t()) :: {:ok, Person.t()} | {:error, :not_found}
  def match_by_channel(platform, channel_identifier)
      when is_binary(platform) and is_binary(channel_identifier) and channel_identifier != "" do
    case Repo.one(
           from c in PersonChannel,
             where: c.platform == ^platform and c.channel_identifier == ^channel_identifier,
             preload: [person: []],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      channel -> {:ok, Repo.preload(channel.person, channels: channels_ordered())}
    end
  end

  def match_by_channel(_platform, _channel_identifier), do: {:error, :not_found}

  @doc """
  Matches a person by priority: email → phone → {platform, channel_identifier}.
  Returns `{:ok, person}` or `{:error, :not_found}`.
  """
  @spec match_person(map()) :: {:ok, Person.t()} | {:error, :not_found}
  def match_person(attrs) do
    match_by_email(attrs)
    |> or_match(fn -> match_by_phone(attrs) end)
    |> or_match(fn -> match_by_channel(attrs) end)
  end

  @doc """
  Finds or creates a person from an incoming channel message.
  On match: back-fills canonical fields if they were missing.
  On miss: creates a partial entry with incomplete: true.
  Returns `{:ok, person}`.
  """
  @spec find_or_create_from_channel(atom() | String.t(), map()) ::
          {:ok, Person.t()} | {:error, term()}
  def find_or_create_from_channel(platform, attrs) do
    platform_str = to_string(platform)
    attrs_with_platform = Map.put_new(attrs, "platform", platform_str)

    case match_person(attrs_with_platform) do
      {:ok, person} ->
        ensure_channel_linked(person, platform_str, attrs_with_platform)
        person = backfill_person(person, attrs_with_platform)
        {:ok, Repo.preload(person, channels: channels_ordered())}

      {:error, :not_found} ->
        create_partial_person(platform_str, attrs_with_platform)
    end
  end

  @doc "Updates last_interaction_at on a PersonChannel to now."
  @spec record_interaction(PersonChannel.t()) :: {:ok, PersonChannel.t()}
  def record_interaction(%PersonChannel{} = channel) do
    channel
    |> PersonChannel.update_changeset(%{last_interaction_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Updates arbitrary fields on a PersonChannel."
  @spec update_channel(PersonChannel.t(), map()) ::
          {:ok, PersonChannel.t()} | {:error, Ecto.Changeset.t()}
  def update_channel(%PersonChannel{} = channel, attrs) do
    channel
    |> PersonChannel.update_changeset(Map.put(attrs, :last_interaction_at, DateTime.utc_now()))
    |> Repo.update()
  end

  @doc """
  Re-assigns all channels from `loser` to `survivor` in a transaction,
  then deletes the loser. Re-evaluates survivor's incomplete flag.

  Accepts either Person structs or integer IDs. Records are re-fetched
  inside the transaction to guard against stale data.
  """
  @spec merge_persons(Person.t() | integer(), Person.t() | integer()) ::
          {:ok, Person.t()} | {:error, term()}
  def merge_persons(survivor_or_id, loser_or_id) do
    survivor_id = if is_struct(survivor_or_id), do: survivor_or_id.id, else: survivor_or_id
    loser_id = if is_struct(loser_or_id), do: loser_or_id.id, else: loser_or_id

    Repo.transaction(fn ->
      # Re-fetch inside the transaction so we work with current data, not stale assigns.
      survivor = Repo.get!(Person, survivor_id)
      loser = Repo.get!(Person, loser_id)

      from(c in PersonChannel, where: c.person_id == ^loser.id)
      |> Repo.update_all(set: [person_id: survivor.id])

      # A partial person's full_name may have been seeded from the channel_identifier
      # as a fallback. Treat it as empty so a real name from the loser takes precedence.
      survivor_channel_ids =
        Repo.all(
          from c in PersonChannel,
            where: c.person_id == ^survivor.id,
            select: c.channel_identifier
        )

      effective_name =
        if survivor.full_name in survivor_channel_ids, do: nil, else: survivor.full_name

      merged_team_ids = (survivor.team_ids ++ loser.team_ids) |> Enum.uniq()

      backfill =
        %{team_ids: merged_team_ids}
        |> maybe_backfill(:full_name, effective_name, loser.full_name)
        |> maybe_backfill(:email, survivor.email, loser.email)
        |> maybe_backfill(:phone, survivor.phone, loser.phone)

      Repo.delete!(loser)

      survivor = Repo.get!(Person, survivor.id) |> Repo.preload(channels: channels_ordered())

      {:ok, survivor} =
        survivor
        |> Person.update_changeset(backfill)
        |> Repo.update()

      survivor
    end)
  end

  defp maybe_backfill(acc, _field, current, _from_loser)
       when is_binary(current) and current != "",
       do: acc

  defp maybe_backfill(acc, field, _current, from_loser)
       when is_binary(from_loser) and from_loser != "",
       do: Map.put(acc, field, from_loser)

  defp maybe_backfill(acc, _field, _current, _from_loser), do: acc

  def get_person!(id), do: Repo.get!(Person, id)

  def get_person_with_channels!(id) do
    Repo.get!(Person, id) |> Repo.preload(channels: channels_ordered())
  end

  def create_person(attrs) do
    attrs = Map.put_new(stringify_keys(attrs), "incomplete", true)
    %Person{} |> Person.changeset(attrs) |> Repo.insert()
  end

  def update_person(%Person{} = person, attrs) do
    person |> Person.update_changeset(attrs) |> Repo.update()
  end

  def delete_person(%Person{} = person), do: Repo.delete(person)

  @doc """
  Searches people by full_name or email using database-side filtering.
  Excludes the given IDs. Returns at most `limit` results.
  """
  @spec search_people(String.t(), [integer()], pos_integer()) :: [Person.t()]
  def search_people(query, exclude_ids \\ [], limit \\ 10) do
    pattern = "%#{escape_like(query)}%"

    from(p in Person,
      where:
        (ilike(p.full_name, ^pattern) or ilike(p.email, ^pattern)) and
          p.id not in ^exclude_ids,
      order_by: p.full_name,
      limit: ^limit
    )
    |> Repo.all()
    |> Repo.preload(channels: channels_ordered())
  end

  # ── Teams ────────────────────────────────────────────────────────────────

  def list_teams do
    Repo.all(from t in Team, order_by: t.name)
  end

  def get_team!(id), do: Repo.get!(Team, id)

  def create_team(attrs) do
    %Team{} |> Team.changeset(attrs) |> Repo.insert()
  end

  def update_team(%Team{} = team, attrs) do
    team |> Team.update_changeset(attrs) |> Repo.update()
  end

  def delete_team(%Team{} = team) do
    team_id = team.id

    Repo.transaction(fn ->
      from(p in Person,
        where: ^team_id in p.team_ids,
        update: [set: [team_ids: fragment("array_remove(team_ids, ?)", ^team_id)]]
      )
      |> Repo.update_all([])

      Repo.delete!(team)
    end)
  end

  def assign_team(%Person{} = person, team_id) when is_integer(team_id) do
    if team_id in person.team_ids do
      {:ok, person}
    else
      update_person(person, %{team_ids: person.team_ids ++ [team_id]})
    end
  end

  def unassign_team(%Person{} = person, team_id) when is_integer(team_id) do
    update_person(person, %{team_ids: List.delete(person.team_ids, team_id)})
  end

  # ── PersonChannels ───────────────────────────────────────────────────────

  def list_person_channels(person_id) do
    Repo.all(from c in PersonChannel, where: c.person_id == ^person_id, order_by: c.weight)
  end

  def get_preferred_channel(person_id) do
    person_id |> list_person_channels() |> List.first()
  end

  def add_channel(attrs) do
    attrs = stringify_keys(attrs)
    person_id = Map.get(attrs, "person_id")
    next_weight = next_channel_weight(person_id)
    attrs = Map.put(attrs, "weight", next_weight)

    %PersonChannel{}
    |> PersonChannel.changeset(attrs)
    |> Repo.insert()
  end

  def delete_channel(%PersonChannel{} = channel), do: Repo.delete(channel)

  def swap_channel_weights(%PersonChannel{} = a, %PersonChannel{} = b) do
    Repo.transaction(fn ->
      {:ok, _} = update_channel(a, %{weight: b.weight})
      {:ok, _} = update_channel(b, %{weight: a.weight})
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp match_by_email(%{"email" => email}) when is_binary(email) and email != "" do
    case Repo.get_by(Person, email: email) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  defp match_by_email(_), do: {:error, :not_found}

  defp match_by_phone(%{"phone" => phone}) when is_binary(phone) and phone != "" do
    case Repo.one(from p in Person, where: p.phone == ^phone, limit: 1) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  defp match_by_phone(_), do: {:error, :not_found}

  defp match_by_channel(%{"platform" => platform, "channel_id" => channel_id})
       when is_binary(platform) and is_binary(channel_id) and channel_id != "" do
    case Repo.one(
           from c in PersonChannel,
             where: c.platform == ^platform and c.channel_identifier == ^channel_id,
             preload: :person,
             limit: 1
         ) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel.person}
    end
  end

  defp match_by_channel(_), do: {:error, :not_found}

  defp ensure_channel_linked(person, platform, attrs) do
    channel_id = Map.get(attrs, "channel_id") || Map.get(attrs, :channel_id)

    existing =
      Repo.one(
        from c in PersonChannel,
          where:
            c.person_id == ^person.id and c.platform == ^platform and
              c.channel_identifier == ^channel_id
      )

    if existing do
      {:ok, existing}
    else
      add_channel(%{
        person_id: person.id,
        platform: platform,
        channel_identifier: channel_id,
        username: Map.get(attrs, "username") || Map.get(attrs, :username),
        display_name: Map.get(attrs, "display_name") || Map.get(attrs, :display_name),
        phone: Map.get(attrs, "phone") || Map.get(attrs, :phone),
        dm_channel_id: Map.get(attrs, "dm_channel_id") || Map.get(attrs, :dm_channel_id)
      })
    end
  end

  defp backfill_person(person, attrs) do
    updates =
      %{}
      |> maybe_put_if_nil(:email, person.email, attrs)
      |> maybe_put_if_nil(:phone, person.phone, attrs)
      |> maybe_put_if_nil(:full_name, person.full_name, attrs, "display_name")

    if map_size(updates) > 0 do
      {:ok, updated} = update_person(person, updates)
      updated
    else
      person
    end
  end

  defp maybe_put_if_nil(acc, field, current_val, attrs, attr_key \\ nil) do
    key = if attr_key, do: attr_key, else: to_string(field)
    incoming = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

    if is_nil(current_val) and is_binary(incoming) and incoming != "" do
      Map.put(acc, field, incoming)
    else
      acc
    end
  end

  defp create_partial_person(platform, attrs) do
    channel_attrs = extract_channel_attrs(attrs)

    Repo.transaction(fn ->
      case insert_partial_person(channel_attrs) do
        {:ok, person} ->
          add_channel(%{
            person_id: person.id,
            platform: platform,
            channel_identifier: channel_attrs.channel_id,
            username: channel_attrs.username,
            display_name: channel_attrs.display_name,
            phone: channel_attrs.phone,
            dm_channel_id: channel_attrs.dm_channel_id
          })

          Repo.preload(person, channels: channels_ordered())

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp extract_channel_attrs(attrs) do
    %{
      channel_id: Map.get(attrs, "channel_id") || Map.get(attrs, :channel_id),
      display_name: Map.get(attrs, "display_name") || Map.get(attrs, :display_name),
      username: Map.get(attrs, "username") || Map.get(attrs, :username),
      email: Map.get(attrs, "email") || Map.get(attrs, :email),
      phone: Map.get(attrs, "phone") || Map.get(attrs, :phone),
      dm_channel_id: Map.get(attrs, "dm_channel_id") || Map.get(attrs, :dm_channel_id)
    }
  end

  defp insert_partial_person(channel_attrs) do
    full_name = channel_attrs.display_name || channel_attrs.channel_id || "Unknown"

    %Person{}
    |> Person.changeset(%{
      full_name: full_name,
      email: channel_attrs.email,
      phone: channel_attrs.phone,
      incomplete: true
    })
    |> Repo.insert()
  end

  defp or_match({:ok, person}, _fallback), do: {:ok, person}
  defp or_match({:error, :not_found}, fallback), do: fallback.()

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Escapes PostgreSQL LIKE/ILIKE special characters so user input is treated literally.
  defp escape_like(str), do: String.replace(str, ["\\", "%", "_"], &"\\#{&1}")

  defp channels_ordered do
    from(c in PersonChannel, order_by: c.weight)
  end

  defp next_channel_weight(nil), do: 0

  defp next_channel_weight(person_id) do
    case Repo.aggregate(
           from(c in PersonChannel, where: c.person_id == ^person_id),
           :max,
           :weight
         ) do
      nil -> 0
      max -> max + 1
    end
  end
end
