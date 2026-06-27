defmodule Zaq.Identity.ActorNormalizer do
  @moduledoc """
  Normalizes trusted identity sources into canonical `%Zaq.Event{actor: ...}` maps.

  Channels may resolve transport identity into `%Zaq.Engine.Messages.Incoming.person`.
  Agent and Engine boundaries use this module to promote that identity into the
  execution actor consumed by tools and workflow steps.
  """

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  @type actor :: map() | nil

  @doc "Returns `event.actor` enriched from `event.request` when the request carries identity."
  @spec normalize_event(Event.t()) :: Event.t()
  def normalize_event(%Event{} = event), do: %{event | actor: from_event_request(event)}

  @doc "Builds an actor from an event-like payload's existing actor and request."
  @spec from_event_request(Event.t() | map()) :: actor()
  def from_event_request(%Event{actor: actor, request: request}), do: from_request(actor, request)

  def from_event_request(%{} = event) do
    actor = Map.get(event, :actor) || Map.get(event, "actor")
    request = Map.get(event, :request) || Map.get(event, "request")
    from_request(actor, request)
  end

  def from_event_request(_), do: nil

  @doc "Enriches `actor` from a request when the request is a supported identity source."
  @spec from_request(actor(), term()) :: actor()
  def from_request(actor, %Incoming{} = incoming), do: from_incoming(actor, incoming)
  def from_request(actor, _request), do: normalize_actor(actor)

  @doc "Enriches `actor` with the person carried by an incoming channel message."
  @spec from_incoming(actor(), Incoming.t()) :: actor()
  def from_incoming(nil, %Incoming{person: nil}), do: nil

  def from_incoming(actor, %Incoming{} = incoming) do
    actor
    |> normalize_actor()
    |> put_actor_defaults(incoming)
    |> from_person_payload(incoming.person)
  end

  @doc "Enriches `actor` with a canonical person payload unless one already exists."
  @spec from_person_payload(actor(), map() | nil) :: actor()
  def from_person_payload(actor, person_payload) do
    actor = normalize_actor(actor)

    cond do
      has_person?(actor) -> actor
      is_nil(normalize_person(person_payload)) -> actor
      is_nil(actor) -> %{person: normalize_person(person_payload)}
      true -> Map.put(actor, :person, normalize_person(person_payload))
    end
  end

  @doc "Returns the canonical person payload from an actor, if present."
  @spec person(actor()) :: map() | nil
  def person(%{person: person}), do: normalize_person(person)
  def person(%{"person" => person}), do: normalize_person(person)
  def person(_), do: nil

  @doc "Returns the actor's effective person ID, including legacy flat actor fields."
  @spec person_id(actor()) :: integer() | nil
  def person_id(actor) do
    person_id_from_person(person(actor)) || legacy_person_id(actor)
  end

  @doc "Returns the actor's effective team IDs."
  @spec team_ids(actor()) :: [integer()]
  def team_ids(actor) do
    case person(actor) do
      %{team_ids: ids} when is_list(ids) -> ids
      %{"team_ids" => ids} when is_list(ids) -> ids
      _ -> []
    end
  end

  @doc false
  @spec normalize_id(term()) :: integer() | nil
  def normalize_id(id) when is_integer(id), do: id

  def normalize_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def normalize_id(_), do: nil

  defp normalize_actor(nil), do: nil

  defp normalize_actor(actor) when is_map(actor) do
    Map.new(actor, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_actor(_), do: nil

  defp put_actor_defaults(nil, %Incoming{} = incoming) do
    %{}
    |> put_if_present(:id, incoming.author_id)
    |> put_if_present(:name, incoming.author_name)
    |> put_if_present(:provider, incoming.provider)
    |> nil_if_empty()
  end

  defp put_actor_defaults(actor, %Incoming{} = incoming) when is_map(actor) do
    actor
    |> put_if_absent(:id, incoming.author_id)
    |> put_if_absent(:name, incoming.author_name)
    |> put_if_absent(:provider, incoming.provider)
  end

  defp put_if_absent(map, key, value) do
    if Map.get(map, key) in [nil, ""], do: put_if_present(map, key, value), else: map
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp nil_if_empty(map) when map == %{}, do: nil
  defp nil_if_empty(map), do: map

  defp has_person?(actor), do: not is_nil(person(actor))

  defp normalize_person(nil), do: nil

  defp normalize_person(person_payload) when is_map(person_payload) do
    id = normalize_id(person_field(person_payload, :id))

    if is_nil(id) do
      nil
    else
      %{
        id: id,
        full_name: person_field(person_payload, :full_name),
        team_ids: normalize_team_ids(person_field(person_payload, :team_ids))
      }
    end
  end

  defp normalize_person(_), do: nil

  defp person_id_from_person(%{id: id}), do: normalize_id(id)
  defp person_id_from_person(%{"id" => id}), do: normalize_id(id)
  defp person_id_from_person(_), do: nil

  defp legacy_person_id(%{person_id: id}), do: normalize_id(id)
  defp legacy_person_id(%{"person_id" => id}), do: normalize_id(id)
  defp legacy_person_id(_), do: nil

  defp person_field(map, field) when is_map(map) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp normalize_team_ids(ids) when is_list(ids), do: Enum.flat_map(ids, &normalize_id_list/1)
  defp normalize_team_ids(_), do: []

  defp normalize_id_list(id) do
    case normalize_id(id) do
      nil -> []
      id -> [id]
    end
  end

  defp normalize_key(key) when is_binary(key) do
    case key do
      "id" -> :id
      "name" -> :name
      "provider" -> :provider
      "person" -> :person
      "person_id" -> :person_id
      other -> other
    end
  end

  defp normalize_key(key), do: key
end
