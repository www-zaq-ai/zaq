defmodule ZaqWeb.Helpers.Selection do
  @moduledoc """
  Pure, parent-owned selection scoped to a list's filters (never its page).

  Explicit mode stores selected IDs; all-matching mode stores only exclusions.
  Callers supply IDs belonging to the current scope. Counts in all-matching mode
  describe the latest known total; resolve actual targets before a destructive action.
  """
  @enforce_keys [:scope]
  defstruct [:scope, mode: :explicit, ids: MapSet.new()]

  @type t :: %__MODULE__{scope: term(), mode: :explicit | :all_matching, ids: MapSet.t()}

  @spec new(term()) :: t()
  def new(scope), do: %__MODULE__{scope: scope}

  @spec scope(t(), term()) :: t()
  def scope(%__MODULE__{scope: scope} = selection, scope), do: selection
  def scope(_selection, scope), do: new(scope)

  @spec clear(t()) :: t()
  def clear(selection), do: new(selection.scope)

  @spec all_matching(t()) :: t()
  def all_matching(selection), do: %{selection | mode: :all_matching, ids: MapSet.new()}

  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{mode: :explicit, ids: ids}, id), do: MapSet.member?(ids, id)
  def member?(%__MODULE__{mode: :all_matching, ids: ids}, id), do: not MapSet.member?(ids, id)

  @spec toggle(t(), term()) :: t()
  def toggle(selection, id) do
    ids = selection.ids
    ids = if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
    %{selection | ids: ids}
  end

  @doc "Selects an incomplete page, or deselects a fully selected page; other pages are preserved."
  @spec toggle_page(t(), [term()]) :: t()
  def toggle_page(selection, ids) do
    selected? = page_state(selection, ids) == :all

    Enum.reduce(ids, selection, fn id, acc ->
      if member?(acc, id) == selected?, do: toggle(acc, id), else: acc
    end)
  end

  @spec page_state(t(), [term()]) :: :none | :mixed | :all
  def page_state(selection, ids) do
    case Enum.count(ids, &member?(selection, &1)) do
      0 -> :none
      n when n == length(ids) -> :all
      _ -> :mixed
    end
  end

  @spec count(t(), non_neg_integer()) :: non_neg_integer()
  def count(%__MODULE__{mode: :explicit, ids: ids}, _total), do: MapSet.size(ids)

  def count(%__MODULE__{mode: :all_matching, ids: ids}, total),
    do: max(total - MapSet.size(ids), 0)
end
