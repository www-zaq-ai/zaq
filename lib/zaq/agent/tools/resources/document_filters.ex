defmodule Zaq.Agent.Tools.Resources.DocumentFilters do
  @moduledoc """
  Validates and applies document category filters for resources.query.

  Only selected document assignments participate. Matching uses a subquery so
  documents remain unique before pagination and counting. An empty ID list matches
  no documents; an omitted list leaves the query unchanged. Authorization belongs
  to Query and is applied before this filter.
  """
  import Ecto.Query
  alias Zaq.Ingestion.Labels.{AssignmentValue, DocumentAssignment}

  @max_label_id 9_223_372_036_854_775_807

  @spec validate(map() | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(filters) when is_map(filters) do
    ids = fetch(filters, "label_ids")
    match = fetch(filters, "label_match")
    values = fetch(filters, "label_values")

    cond do
      ids != :error and not valid_ids?(ids) ->
        {:error, {:invalid_filter, "label_ids"}}

      values != :error and not valid_values?(values) ->
        {:error, {:invalid_filter, "label_values"}}

      invalid_match?(match, ids, values) ->
        {:error, {:invalid_filter, "label_match"}}

      true ->
        :ok
    end
  end

  defp invalid_match?(match, ids, values) do
    match not in [:error, {:ok, "any"}, {:ok, "all"}] or
      (match != :error and ids == :error and values == :error)
  end

  @spec apply(Ecto.Queryable.t(), map()) :: Ecto.Query.t()
  def apply(query, filters) do
    query =
      case fetch(filters, "label_ids") do
        :error -> query
        {:ok, ids} -> matching_documents(query, Enum.uniq(ids), fetch(filters, "label_match"))
      end

    case fetch(filters, "label_values") do
      :error ->
        query

      {:ok, pairs} ->
        matching_values(query, normalized_pairs(pairs), fetch(filters, "label_match"))
    end
  end

  defp matching_documents(query, ids, match) do
    assignments =
      from a in DocumentAssignment,
        where: a.selected and a.label_id in ^ids,
        group_by: a.document_id,
        select: a.document_id

    assignments =
      if match == {:ok, "all"},
        do: from(a in assignments, having: count(a.label_id, :distinct) == ^length(ids)),
        else: assignments

    from d in query, where: d.id in subquery(assignments)
  end

  defp matching_values(query, pairs, match) do
    condition =
      Enum.reduce(pairs, dynamic(false), fn {id, value}, condition ->
        pair =
          if is_nil(value),
            do: dynamic([a], a.label_id == ^id and is_nil(a.value)),
            else: dynamic([a], a.label_id == ^id and a.value == ^value)

        dynamic(^condition or ^pair)
      end)

    assignments =
      from a in DocumentAssignment,
        where: a.selected,
        where: ^condition,
        group_by: a.document_id,
        select: a.document_id

    assignments =
      if match == {:ok, "all"},
        do: from(a in assignments, having: count(a.label_id, :distinct) == ^length(pairs)),
        else: assignments

    from d in query, where: d.id in subquery(assignments)
  end

  defp valid_values?({:ok, pairs}) when is_list(pairs) and length(pairs) <= 100,
    do: Enum.all?(pairs, &valid_pair?/1)

  defp valid_values?(_), do: false

  defp valid_pair?(pair) when is_map(pair) do
    with true <- Enum.all?(Map.keys(pair), &(&1 in ["label_id", "value", :label_id, :value])),
         {:ok, id} <- fetch(pair, "label_id"),
         {:ok, value} <- fetch(pair, "value") do
      valid_ids?({:ok, [id]}) and AssignmentValue.valid?(value)
    else
      _ -> false
    end
  end

  defp valid_pair?(_), do: false

  defp normalized_pairs(pairs) do
    pairs
    |> Enum.map(fn pair ->
      {:ok, id} = fetch(pair, "label_id")
      {:ok, value} = fetch(pair, "value")
      {id, AssignmentValue.normalize(value)}
    end)
    |> Enum.uniq()
  end

  defp valid_ids?({:ok, ids}) when is_list(ids) and length(ids) <= 100,
    do: Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= @max_label_id))

  defp valid_ids?(_), do: false

  defp fetch(filters, key) do
    case Map.fetch(filters, key) do
      :error -> Map.fetch(filters, key_atom(key))
      value -> value
    end
  end

  defp key_atom("label_ids"), do: :label_ids
  defp key_atom("label_values"), do: :label_values
  defp key_atom("label_match"), do: :label_match
  defp key_atom("label_id"), do: :label_id
  defp key_atom("value"), do: :value
end
