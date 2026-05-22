defmodule Zaq.Engine.PeopleGateway do
  @moduledoc """
  Dispatches BO people-domain commands from Engine boundary actions.
  """

  alias Zaq.Accounts.People

  def dispatch(:filter, %{filters: filters, opts: opts}) when is_map(filters) and is_list(opts),
    do: People.filter_people(filters, opts)

  def dispatch(:get_with_channels, %{id: id}) do
    case People.get_person_with_channels(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  def dispatch(:get, %{id: id}) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  def dispatch(:create, %{attrs: attrs}) when is_map(attrs), do: People.create_person(attrs)

  def dispatch(:update, %{id: id, attrs: attrs}) when is_map(attrs) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> People.update_person(person, attrs)
    end
  end

  def dispatch(:delete, %{id: id}) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> People.delete_person(person)
    end
  end

  def dispatch(:bulk_delete, %{person_ids: person_ids}) when is_list(person_ids),
    do: People.bulk_delete_people(Enum.map(person_ids, &normalize_id/1))

  def dispatch(:merge, %{survivor_id: survivor_id, loser_id: loser_id}),
    do: People.merge_persons(normalize_id(survivor_id), normalize_id(loser_id))

  def dispatch(:search, %{query: query, exclude_ids: exclude_ids, limit: limit})
      when is_binary(query) and is_list(exclude_ids) and is_integer(limit),
      do: {:ok, People.search_people(query, exclude_ids, limit)}

  def dispatch(:assign_team, %{person_id: person_id, team_id: team_id}) do
    case People.get_person(normalize_id(person_id)) do
      nil -> {:error, :not_found}
      person -> People.assign_team(person, normalize_id(team_id))
    end
  end

  def dispatch(:unassign_team, %{person_id: person_id, team_id: team_id}) do
    case People.get_person(normalize_id(person_id)) do
      nil -> {:error, :not_found}
      person -> People.unassign_team(person, normalize_id(team_id))
    end
  end

  def dispatch(:add_channel, %{attrs: attrs}) when is_map(attrs), do: People.add_channel(attrs)

  def dispatch(:update_channel, %{id: id, attrs: attrs}) when is_map(attrs) do
    case find_channel(normalize_id(id)) do
      nil -> {:error, :not_found}
      channel -> People.update_channel(channel, attrs)
    end
  end

  def dispatch(:delete_channel, %{id: id}) do
    case find_channel(normalize_id(id)) do
      nil -> {:error, :not_found}
      channel -> People.delete_channel(channel)
    end
  end

  def dispatch(:swap_channel_weights, %{a_id: a_id, b_id: b_id}) do
    with a when not is_nil(a) <- find_channel(normalize_id(a_id)),
         b when not is_nil(b) <- find_channel(normalize_id(b_id)) do
      People.swap_channel_weights(a, b)
    else
      _ -> {:error, :not_found}
    end
  end

  def dispatch(:list_teams, %{}), do: {:ok, People.list_teams()}

  def dispatch(:get_team, %{id: id}) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> {:ok, team}
    end
  end

  def dispatch(:create_team, %{attrs: attrs}) when is_map(attrs), do: People.create_team(attrs)

  def dispatch(:update_team, %{id: id, attrs: attrs}) when is_map(attrs) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> People.update_team(team, attrs)
    end
  end

  def dispatch(:delete_team, %{id: id}) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> People.delete_team(team)
    end
  end

  def dispatch(_op, _params), do: {:error, :unsupported_people_operation}

  defp find_channel(id) do
    People.get_channel(id)
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp normalize_id(id), do: id
end
