defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectEvents do
  @moduledoc """
  Stateless helpers for Connect grant event flows.
  """

  def find_grant(grants, id) when is_list(grants) do
    Enum.find(grants, &(to_string(&1.id) == to_string(id)))
  end

  def find_grant(_grants, _id), do: nil

  def run_grant_action(grants, id, action_fun) when is_function(action_fun, 1) do
    case find_grant(grants, id) do
      nil ->
        :not_found

      grant ->
        case action_fun.(grant) do
          {:ok, _} = ok -> {:ok, grant, ok}
          {:error, _} = error -> {:error, grant, error}
          other -> {:other, grant, other}
        end
    end
  end
end
