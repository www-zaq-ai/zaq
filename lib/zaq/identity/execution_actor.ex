defmodule Zaq.Identity.ExecutionActor do
  @moduledoc """
  Validates trusted execution actors and extracts their stable identity.

  Person actors use nested `person.id`; legacy `person_id` is promoted using
  `ActorNormalizer`'s existing integer normalization (including zero and negative
  integers). Explicit non-Person actors require a known kind and a nonblank
  subject minted by the trusted origin. Subjects are opaque and are not trimmed.

  Metadata is retained but never participates in identity. Missing, malformed or
  contradictory declarations never fall back to another identity or grant access.
  This contract validates shape, not authentication or permission to assert it.
  """

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Identity.ActorNormalizer

  @kinds [:bo_user, :channel_subject, :anonymous, :system]
  @actor_keys [:person, :person_id, :kind, :subject, :id, :name, :provider, :user_id]
  @person_keys [:id, :full_name, :team_ids]
  @type error :: :missing_execution_actor | :invalid_execution_actor
  @type kind :: :bo_user | :channel_subject | :anonymous | :system
  @type identity :: {:person, integer()} | {kind(), String.t()}

  @doc "Returns a canonical actor, rejecting absent or conflicting identity declarations."
  @spec validate(term()) :: {:ok, map()} | {:error, error()}
  def validate(nil), do: {:error, :missing_execution_actor}

  def validate(actor) when is_map(actor) and not is_struct(actor) do
    with {:ok, actor} <- canonical_keys(actor, @actor_keys) do
      validate_declaration(actor)
    end
  end

  def validate(_), do: invalid()

  @doc "Validates raw event identity before trusted Incoming enrichment can erase conflicting declarations."
  @spec from_event_request(map()) :: {:ok, map()} | {:error, error()}
  def from_event_request(event) when is_map(event) do
    actor = Map.get(event, :actor) || Map.get(event, "actor")
    request = Map.get(event, :request) || Map.get(event, "request")

    candidate =
      case {actor, request} do
        {nil, %Incoming{person: person}} when not is_nil(person) -> %{person: person}
        _ -> actor
      end

    with {:ok, actor} <- validate(candidate) do
      request
      |> then(&ActorNormalizer.from_request(actor, &1))
      |> validate()
    end
  end

  @doc "Returns the stable principal key, independent of scope, names, teams and other metadata."
  @spec identity(term()) :: {:ok, identity()} | {:error, error()}
  def identity(actor) do
    with {:ok, canonical} <- validate(actor) do
      case canonical do
        %{person: %{id: id}} -> {:ok, {:person, id}}
        %{kind: kind, subject: subject} -> {:ok, {kind, subject}}
      end
    end
  end

  defp validate_declaration(actor) do
    cond do
      Map.has_key?(actor, :person) -> validate_person(actor, actor.person)
      Map.has_key?(actor, :person_id) -> validate_person(actor, %{id: actor.person_id})
      true -> validate_non_person(actor)
    end
  end

  defp validate_person(actor, person) when is_map(person) do
    with false <- Map.has_key?(actor, :kind) or Map.has_key?(actor, :subject),
         {:ok, person} <- canonical_keys(person, @person_keys),
         %{id: id} = normalized <- ActorNormalizer.person(%{person: person}),
         true <- consistent_legacy_id?(actor, id) do
      canonical = Map.put(actor, :person, Map.merge(person, normalized))

      canonical =
        if Map.has_key?(actor, :person_id),
          do: Map.put(canonical, :person_id, id),
          else: canonical

      {:ok, canonical}
    else
      _ -> invalid()
    end
  end

  defp validate_person(_actor, _person), do: invalid()

  defp consistent_legacy_id?(actor, id) do
    case Map.fetch(actor, :person_id) do
      :error -> true
      {:ok, value} -> ActorNormalizer.normalize_id(value) == id
    end
  end

  defp validate_non_person(%{kind: kind, subject: subject} = actor) when is_binary(subject) do
    kind = Enum.find(@kinds, &(kind == &1 or kind == Atom.to_string(&1)))

    if kind && String.valid?(subject) && String.trim(subject) != "" do
      {:ok, Map.put(actor, :kind, kind)}
    else
      invalid()
    end
  end

  defp validate_non_person(_), do: invalid()

  # Check before normalization: Map.new/2 would silently pick one alias. Even
  # metadata aliases must agree; no dynamic atoms are created from JSON keys.
  defp canonical_keys(map, keys) do
    Enum.reduce_while(keys, {:ok, map}, fn key, {:ok, acc} ->
      string_key = Atom.to_string(key)

      case {Map.fetch(acc, key), Map.fetch(acc, string_key)} do
        {{:ok, left}, {:ok, right}} when left != right ->
          {:halt, invalid()}

        {_, {:ok, value}} ->
          {:cont, {:ok, acc |> Map.delete(string_key) |> Map.put(key, value)}}

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp invalid, do: {:error, :invalid_execution_actor}
end
