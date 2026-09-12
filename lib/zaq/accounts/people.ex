defmodule Zaq.Accounts.People do
  @moduledoc """
  Context for managing people, their communication channels, and teams.
  Owns profile and protected merge-result persistence. Combined resource requests
  merge persisted participants first, then apply ordinary edits to the returned
  survivor within one outer transaction; explicit edits override merge precedence.
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Accounts.PersonMerger
  alias Zaq.Accounts.Team
  alias Zaq.Repo

  # ── People ──────────────────────────────────────────────────────────────

  def list_people(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      if limit,
        do: from(p in Person, order_by: p.full_name, limit: ^limit),
        else: from(p in Person, order_by: p.full_name)

    people = Repo.all(query)
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

  @doc """
  Resolves a filter-scoped selection to a frozen list of IDs, without pagination.
  In explicit mode `ids` are inclusions; in all-matching mode they are exclusions.
  Filters are required (an explicit empty map means unfiltered). Malformed input
  is rejected rather than silently widening a destructive action's scope.
  """
  @spec resolve_selection(map()) :: {:ok, [pos_integer()]} | {:error, :invalid_selection}
  def resolve_selection(%{mode: mode, filters: filters, ids: ids})
      when mode in [:explicit, :all_matching] do
    if valid_selection_filters?(filters) and valid_person_ids?(ids) do
      query = build_filter_query(filters)

      query =
        if mode == :explicit,
          do: from(p in query, where: p.id in ^ids),
          else: from(p in query, where: p.id not in ^ids)

      {:ok, Repo.all(from(p in query, select: p.id))}
    else
      {:error, :invalid_selection}
    end
  end

  def resolve_selection(_), do: {:error, :invalid_selection}

  defp valid_selection_filters?(filters) when is_map(filters) and not is_struct(filters) do
    Enum.all?(filters, fn
      {key, value} when key in ["name", "email", "phone"] ->
        is_binary(value)

      {"complete", value} ->
        value in ["all", "complete", "incomplete"]

      {"team_id", ""} ->
        true

      {"team_id", value} when is_binary(value) ->
        case Integer.parse(value) do
          {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp valid_selection_filters?(_), do: false

  defp valid_person_ids?(ids) when is_list(ids),
    do: Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= 9_223_372_036_854_775_807))

  defp valid_person_ids?(_), do: false

  defp build_filter_query(filters) do
    name = Map.get(filters, "name", "")
    email = Map.get(filters, "email", "")
    phone = Map.get(filters, "phone", "")
    complete = Map.get(filters, "complete", "all")
    team_id = Map.get(filters, "team_id", "")

    query = from(p in Person, order_by: [p.full_name, p.id])

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
    case find_matching_channel(PersonChannel, platform, channel_identifier) do
      nil -> {:error, :not_found}
      channel -> {:ok, get_person_with_channels!(channel.person_id)}
    end
  end

  def match_by_channel(_platform, _channel_identifier), do: {:error, :not_found}

  @doc """
  Matches a person by priority: email → phone → {platform, channel_identifier}.
  Returns `{:ok, person}` or `{:error, :not_found}`.
  """
  @spec match_person(map()) :: {:ok, Person.t()} | {:error, :not_found}
  def match_person(attrs) do
    attrs |> stringify_keys() |> match_normalized_person()
  end

  defp match_normalized_person(attrs) do
    match_by_email(attrs)
    |> or_match(fn -> match_by_phone(attrs) end)
    |> or_match(fn -> match_by_channel(attrs) end)
  end

  @doc """
  Finds or creates a person from an incoming channel message.
  On match: back-fills canonical fields if they were missing.
  On miss: creates a partial entry with incomplete: true.
  Returns `{:ok, person}` or a controlled error; failed links roll back all writes.
  """
  @spec find_or_create_from_channel(atom() | String.t(), map()) ::
          {:ok, Person.t()} | {:error, term()}
  def find_or_create_from_channel(platform, attrs) do
    retry? = not Repo.in_transaction?()
    platform_str = platform |> to_string() |> canonical_platform()

    attrs_with_platform =
      attrs
      |> stringify_keys()
      |> Map.put_new("platform", platform_str)

    case discover_person(platform_str, attrs_with_platform) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        # Retry only after the failed transaction has rolled back. A concurrent
        # discoverer may now own the unique identity; contradictory owners still
        # fail the ordinary linking path, without reassignment or automatic merge.
        if retry? and unique_error?(changeset),
          do: discover_person(platform_str, attrs_with_platform),
          else: error

      result ->
        result
    end
  end

  defp unique_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] in [
          "people_email_index",
          "channels_platform_channel_identifier_index"
        ]
    end)
  end

  defp discover_person(platform, attrs) do
    Repo.transaction(fn ->
      person =
        case match_normalized_person(attrs) do
          {:ok, person} ->
            person

          {:error, :not_found} ->
            attrs |> insert_partial_person() |> linked!()
        end

      link_discovery_channels(person, platform, attrs)
      person = backfill_person(person, attrs) |> linked!()
      Repo.preload(person, [channels: channels_ordered()], force: true)
    end)
  end

  defp linked!({:ok, value}), do: value
  defp linked!({:error, reason}), do: Repo.rollback(reason)

  @doc "Updates last_interaction_at on a PersonChannel to now."
  @spec record_interaction(PersonChannel.t()) :: {:ok, PersonChannel.t()}
  def record_interaction(%PersonChannel{} = channel) do
    channel
    |> PersonChannel.update_changeset(%{last_interaction_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Updates editable channel fields without changing ownership; defaults activity to now."
  @spec update_channel(PersonChannel.t(), map()) ::
          {:ok, PersonChannel.t()} | {:error, Ecto.Changeset.t()}
  def update_channel(%PersonChannel{} = channel, attrs) do
    normalized =
      attrs |> stringify_keys() |> Map.put_new("last_interaction_at", DateTime.utc_now())

    channel
    |> PersonChannel.update_changeset(normalized)
    |> Repo.update()
  end

  @doc """
  Protected owner operation persisting a calculated channel reconciliation result.
  Only PersonMerger supplies these attributes within its merge transaction,
  including the survivor's person_id, reconciled fields, and latest interaction
  timestamp (which may be nil). No activity timestamp is synthesized for a merge.
  Ordinary requests must use `update_channel/2`, which cannot change ownership.
  """
  @spec apply_channel_merge_result(PersonChannel.t(), map()) ::
          {:ok, PersonChannel.t()} | {:error, Ecto.Changeset.t()}
  def apply_channel_merge_result(%PersonChannel{} = channel, attrs) do
    channel |> PersonChannel.changeset(attrs) |> Repo.update()
  end

  @doc """
  Merges one or many people into the explicit survivor atomically. IDs and structs
  share the same policy. Survivor values win; missing values are filled in loser
  ID order from an original snapshot. Teams and direct rights are unioned.

  Losers are deleted. By default their IDs and display history are retained on the
  survivor. `retain_redirect: false` forgets new loser IDs, preserving inherited aliases.
  Workflow snapshots/results and approval audit records are never rewritten.
  """
  @spec merge_persons(Person.t() | integer(), Person.t() | integer() | list(), keyword()) ::
          {:ok, Person.t()} | {:error, term()}
  def merge_persons(survivor_or_id, losers, opts \\ []) do
    PersonMerger.merge(survivor_or_id, losers, opts)
  end

  @doc """
  Optionally merges persisted people, then updates the returned survivor and its
  channels in one transaction. Explicit edits override merged values.

  Merge precedence is expressed by `merge_precedence`: `"person"` keeps the
  requested person as the survivor, while `"other"` keeps `merge_with_person_id`.
  Omitted fields retain merge precedence. Channel edits must name a retained ID;
  discarded IDs return `:channel_not_found` and roll back the entire request.
  """
  @spec update_person_resource(Person.t() | integer(), map(), [map()], map()) ::
          {:ok, Person.t()} | {:error, term()}
  def update_person_resource(person_or_id, attrs \\ %{}, channels \\ [], merge_opts \\ %{}) do
    person_id = if is_struct(person_or_id), do: person_or_id.id, else: person_or_id

    Repo.transaction(fn ->
      with %Person{} = person <- get_person(person_id),
           {:ok, final_person} <- update_resource(person, attrs, channels, merge_opts) do
        final_person
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Retrieves a current Person by its ID or retained historical ID in one query."
  @spec get_person(integer() | String.t() | nil) :: Person.t() | nil
  def get_person(id) when is_nil(id), do: nil

  def get_person(id) do
    id =
      Ecto.Type.cast(:integer, id)
      |> case do
        {:ok, id} -> id
        :error -> -1
      end

    Repo.one(
      from p in Person,
        where: p.id == ^id or fragment("? @> ARRAY[?]::bigint[]", p.merged_person_ids, ^id)
    )
  end

  def get_person!(id), do: get_person(id) || raise(Ecto.NoResultsError, queryable: Person)

  def get_person_with_channels!(id) do
    get_person!(id) |> Repo.preload(channels: channels_ordered())
  end

  def get_person_with_channels(id) do
    case get_person(id) do
      nil -> nil
      person -> Repo.preload(person, channels: channels_ordered())
    end
  end

  def create_person(attrs) do
    attrs = Map.put_new(stringify_keys(attrs), "incomplete", true)
    persist_person(Person.changeset(%Person{}, attrs), :insert)
  end

  def update_person(%Person{} = person, attrs) do
    persist_person(Person.update_changeset(person, stringify_keys(attrs)), :update)
  end

  @doc """
  Protected owner operation persisting a calculated identity consolidation result
  in one update. Only the merger supplies these attributes, including aliases and
  history; ordinary requests must use `update_person/2`. Channel reconciliation is
  already planned and applied by the merger within the same transaction.
  """
  @spec apply_merge_result(Person.t(), map()) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def apply_merge_result(%Person{} = person, attrs) do
    person |> Person.merge_result_changeset(attrs) |> Repo.update()
  end

  defp persist_person(changeset, operation) do
    link_email? = operation == :insert or Ecto.Changeset.changed?(changeset, :email)

    Repo.transaction(fn ->
      person = apply(Repo, operation, [changeset]) |> linked!()
      email_link = if link_email?, do: maybe_link_email_channel(person), else: {:ok, nil}

      case email_link do
        {:ok, _} ->
          person

        {:error, error} ->
          # Person forms render email, while channel forms render identifier.
          # Keep the original Person changes and never expose another owner.
          Repo.rollback(email_link_error(changeset, error, operation))
      end
    end)
  end

  defp email_link_error(changeset, error, operation) do
    changeset =
      Enum.reduce(error.errors, changeset, fn {_field, {message, opts}}, acc ->
        Ecto.Changeset.add_error(acc, :email, message, opts)
      end)

    %{changeset | action: operation}
  end

  def delete_person(%Person{} = person), do: Repo.delete(person)

  @doc """
  Deletes multiple people by ID in a single transaction and returns a summary.

  All deletions are atomic: if any person fails to delete the entire operation
  is rolled back. Associated channels are removed via DB cascade.
  """
  @spec bulk_delete_people([integer()]) ::
          {:ok, %{deleted_count: non_neg_integer(), failed_ids: [integer()]}} | {:error, term()}
  def bulk_delete_people(person_ids) do
    if valid_person_ids?(person_ids),
      do: delete_people_atomically(Enum.uniq(person_ids)),
      else: {:error, :invalid_person_ids}
  end

  defp delete_people_atomically(ids) do
    if ids == [] do
      {:ok, %{deleted_count: 0, failed_ids: []}}
    else
      sage = Enum.reduce(ids, Sage.new(), &add_delete_step/2)

      case Sage.transaction(sage, Repo) do
        {:ok, _, _} -> {:ok, %{deleted_count: length(ids), failed_ids: []}}
        {:error, {:not_found, id}} -> {:ok, %{deleted_count: 0, failed_ids: [id]}}
        {:error, {:delete_failed, id}} -> {:ok, %{deleted_count: 0, failed_ids: [id]}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp add_delete_step(id, sage) do
    Sage.run(sage, {:delete, id}, fn _effects, _opts -> delete_person_step(id) end)
  end

  defp delete_person_step(id) do
    case get_person(id) do
      nil -> {:error, {:not_found, id}}
      person -> delete_or_error(person, id)
    end
  end

  defp delete_or_error(person, id) do
    case delete_person(person) do
      {:ok, _} -> {:ok, :deleted}
      {:error, _} -> {:error, {:delete_failed, id}}
    end
  end

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

  def get_team(id), do: Repo.get(Team, id)
  def get_team!(id), do: Repo.get!(Team, id)
  def everyone_team, do: Repo.get_by!(Team, system_key: "everyone")

  def create_team(attrs) do
    %Team{} |> Team.changeset(attrs) |> Repo.insert()
  end

  def update_team(%Team{} = team, attrs) do
    team |> Team.update_changeset(attrs) |> Repo.update()
  end

  def delete_team(%Team{system_key: key}) when is_binary(key) and key != "",
    do: {:error, :system_team}

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
    update_team_membership(person.id, team_id, fn locked ->
      if team_id in locked.team_ids,
        do: {:ok, locked},
        else: update_person(locked, %{team_ids: locked.team_ids ++ [team_id]})
    end)
  end

  def unassign_team(%Person{} = person, team_id) when is_integer(team_id) do
    update_team_membership(person.id, team_id, fn locked ->
      update_person(locked, %{team_ids: List.delete(locked.team_ids, team_id)})
    end)
  end

  defp update_team_membership(person_id, team_id, change) do
    if system_team_id?(team_id) do
      {:error, :system_team}
    else
      Repo.transaction(fn -> change_teams!(person_id, change) end)
    end
  end

  defp change_teams!(person_id, change) do
    case person_id |> lock_current_person!() |> change.() do
      {:ok, updated} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_current_person!(original_id) do
    case get_person(original_id) do
      nil ->
        Repo.rollback(:not_found)

      person ->
        # Lock only this canonical row, never the global merge lock or another
        # live Person row. A merge can delete it while FOR UPDATE waits. Under
        # READ COMMITTED, retry original-ID resolution on a fresh snapshot so
        # an inherited alias follows the survivor rather than using stale teams.
        case Repo.one(from p in Person, where: p.id == ^person.id, lock: "FOR UPDATE") do
          nil -> lock_current_person!(original_id)
          locked -> locked
        end
    end
  end

  defp system_team_id?(team_id),
    do: Repo.exists?(from t in Team, where: t.id == ^team_id and not is_nil(t.system_key))

  # ── PersonChannels ───────────────────────────────────────────────────────

  def list_person_channels(person_id) do
    Repo.all(from c in PersonChannel, where: c.person_id == ^person_id, order_by: c.weight)
  end

  def get_channel(id), do: Repo.get(PersonChannel, id)

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
    email = Person.normalize_email(email)

    case email && Repo.get_by(Person, email: email) do
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
    match_by_channel(platform, channel_id)
  end

  defp match_by_channel(_), do: {:error, :not_found}

  defp find_matching_channel(query, platform, identifier) do
    identifier = PersonChannel.normalize_identifier(platform, identifier)

    if identifier do
      Repo.one(
        from c in query,
          where: c.platform == ^platform and c.channel_identifier == ^identifier,
          order_by: c.id,
          limit: 1
      )
    end
  end

  defp ensure_channel_linked(person, platform, attrs) do
    channel_id = Map.get(attrs, "channel_id")

    existing =
      find_matching_channel(
        from(c in PersonChannel, where: c.person_id == ^person.id),
        platform,
        channel_id
      )

    if existing do
      {:ok, existing}
    else
      add_channel(%{
        person_id: person.id,
        platform: platform,
        channel_identifier: channel_id,
        username: Map.get(attrs, "username"),
        display_name: Map.get(attrs, "display_name"),
        phone: Map.get(attrs, "phone"),
        dm_channel_id: Map.get(attrs, "dm_channel_id")
      })
    end
  end

  defp maybe_update_person_fields(%Person{} = person, nil), do: {:ok, person}
  defp maybe_update_person_fields(%Person{} = person, attrs) when attrs == %{}, do: {:ok, person}

  defp maybe_update_person_fields(%Person{} = person, attrs) when is_map(attrs),
    do: update_person(person, attrs)

  defp maybe_update_person_fields(_person, _attrs), do: {:error, :invalid_person_attrs}

  defp upsert_person_channels(_person_id, nil), do: {:ok, []}
  defp upsert_person_channels(_person_id, []), do: {:ok, []}

  defp upsert_person_channels(person_id, channels) when is_list(channels) do
    Enum.reduce_while(channels, {:ok, []}, fn channel_attrs, {:ok, acc} ->
      case upsert_person_channel(person_id, channel_attrs) do
        {:ok, channel} -> {:cont, {:ok, [channel | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_person_channels(_person_id, _channels), do: {:error, :invalid_channels}

  defp upsert_person_channel(person_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, "id") do
      nil ->
        attrs
        |> Map.put("person_id", person_id)
        |> add_channel()

      id ->
        case Repo.get_by(PersonChannel, id: id, person_id: person_id) do
          nil ->
            {:error, :channel_not_found}

          channel ->
            attrs
            |> Map.drop(["id", "person_id"])
            |> then(&update_channel(channel, &1))
        end
    end
  end

  defp upsert_person_channel(_person_id, _attrs), do: {:error, :invalid_channel}

  defp update_resource(person, attrs, channels, merge_opts) when is_map(merge_opts) do
    merge_with_person_id =
      Map.get(merge_opts, :merge_with_person_id) || Map.get(merge_opts, "merge_with_person_id")

    if is_nil(merge_with_person_id) do
      update_resource(person, attrs, channels, nil)
    else
      precedence =
        Map.get(merge_opts, :merge_precedence) || Map.get(merge_opts, "merge_precedence") ||
          "person"

      with {:ok, merged} <- merge_resource_people(person, merge_with_person_id, precedence) do
        update_resource(merged, attrs, channels, nil)
      end
    end
  end

  defp update_resource(person, attrs, channels, nil) do
    with {:ok, updated} <- maybe_update_person_fields(person, attrs),
         {:ok, _channels} <- upsert_person_channels(updated.id, channels) do
      {:ok, get_person_with_channels!(updated.id)}
    end
  end

  defp update_resource(_person, _attrs, _channels, _merge_opts), do: {:error, :invalid_merge}

  defp merge_resource_people(person, other_id, "person"), do: merge_persons(person.id, other_id)
  defp merge_resource_people(person, other_id, "other"), do: merge_persons(other_id, person.id)

  defp merge_resource_people(_person, _other_id, _precedence),
    do: {:error, :invalid_merge_precedence}

  defp canonical_platform("email:imap"), do: "email"
  defp canonical_platform(platform), do: platform

  # Called from create_person/update_person with a resolved Person struct.
  defp maybe_link_email_channel(%Person{email: email} = person)
       when is_binary(email) and email != "" do
    ensure_channel_linked(person, "email", %{
      "channel_id" => email,
      "email" => email,
      "display_name" => person.full_name
    })
  end

  defp maybe_link_email_channel(_person), do: {:ok, nil}

  defp link_discovery_channels(person, platform, attrs) do
    email = if is_binary(attrs["email"]), do: Person.normalize_email(attrs["email"])
    email_attrs = %{"channel_id" => email, "display_name" => attrs["display_name"]}
    links = [{platform, attrs}] ++ if(email, do: [{"email", email_attrs}], else: [])

    links
    |> Enum.uniq_by(fn {platform, attrs} ->
      {platform, PersonChannel.normalize_identifier(platform, attrs["channel_id"])}
    end)
    |> Enum.each(fn {platform, attrs} ->
      ensure_channel_linked(person, platform, attrs) |> linked!()
    end)
  end

  defp backfill_person(person, attrs) do
    # If full_name looks like an email address it was seeded from a channel identifier.
    # Treat it as absent so an incoming display_name can replace it.
    effective_name =
      if is_binary(person.full_name) and String.contains?(person.full_name, "@"),
        do: nil,
        else: person.full_name

    updates =
      %{}
      |> maybe_put_if_nil(:email, person.email, attrs)
      |> maybe_put_if_nil(:phone, person.phone, attrs)
      |> maybe_put_if_nil(:full_name, effective_name, attrs, "display_name")

    if map_size(updates) > 0 do
      person |> Person.update_changeset(updates) |> Repo.update()
    else
      {:ok, person}
    end
  end

  defp maybe_put_if_nil(acc, field, current_val, attrs, attr_key \\ nil) do
    key = if attr_key, do: attr_key, else: to_string(field)
    incoming = Map.get(attrs, key)

    if is_nil(current_val) and is_binary(incoming) and incoming != "" do
      Map.put(acc, field, incoming)
    else
      acc
    end
  end

  defp insert_partial_person(channel_attrs) do
    full_name = channel_attrs["display_name"] || channel_attrs["channel_id"] || "Unknown"

    %Person{}
    |> Person.changeset(%{
      full_name: full_name,
      email: channel_attrs["email"],
      phone: channel_attrs["phone"],
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
