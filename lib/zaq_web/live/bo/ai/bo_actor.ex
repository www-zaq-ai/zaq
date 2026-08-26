defmodule ZaqWeb.Live.BO.AI.BOActor do
  @moduledoc """
  Builds trusted BO actor maps for AI LiveViews.

  `skip_permissions` is granted only to `super_admin` users; regular BO users still need
  explicit resource grants.
  """

  @spec build(map() | nil) :: map()
  def build(current_user) do
    %{
      user_id: user_attr(current_user, :id),
      person_id: user_attr(current_user, :person_id),
      name: user_attr(current_user, :username),
      provider: "bo",
      skip_permissions: super_admin?(current_user)
    }
  end

  @spec super_admin?(map() | nil) :: boolean()
  def super_admin?(%{role: %{name: "super_admin"}}), do: true
  def super_admin?(_), do: false

  defp user_attr(user, key) when is_map(user),
    do: Map.get(user, key) || Map.get(user, Atom.to_string(key))

  defp user_attr(_user, _key), do: nil
end
