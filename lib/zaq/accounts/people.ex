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

  def get_person!(id), do: Repo.get!(Person, id)

  def get_person_with_channels!(id) do
    Repo.get!(Person, id) |> Repo.preload(channels: channels_ordered())
  end

  def create_person(attrs) do
    %Person{} |> Person.changeset(attrs) |> Repo.insert()
  end

  def update_person(%Person{} = person, attrs) do
    person |> Person.update_changeset(attrs) |> Repo.update()
  end

  def delete_person(%Person{} = person), do: Repo.delete(person)

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

    %PersonChannel{} |> PersonChannel.changeset(attrs) |> Repo.insert()
  end

  def update_channel(%PersonChannel{} = channel, attrs) do
    channel |> PersonChannel.update_changeset(attrs) |> Repo.update()
  end

  def delete_channel(%PersonChannel{} = channel), do: Repo.delete(channel)

  def swap_channel_weights(%PersonChannel{} = a, %PersonChannel{} = b) do
    Repo.transaction(fn ->
      {:ok, _} = update_channel(a, %{weight: b.weight})
      {:ok, _} = update_channel(b, %{weight: a.weight})
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

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
