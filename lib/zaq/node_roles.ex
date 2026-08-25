defmodule Zaq.NodeRoles do
  @moduledoc """
  Runtime role resolution for multi-node deployments.

  `ROLES` env takes precedence over `:zaq, :roles` config.
  """

  @roles [:bo, :agent, :ingestion, :storage, :channels, :engine]

  @doc "Returns every concrete node role ZAQ knows how to route."
  @spec all() :: [atom()]
  def all, do: @roles

  @spec current() :: [atom()]
  def current do
    case System.get_env("ROLES") do
      nil -> Application.get_env(:zaq, :roles, [:all])
      roles_str -> parse(roles_str)
    end
  end

  @spec has_any?([atom()]) :: boolean()
  def has_any?(required_roles) when is_list(required_roles) do
    roles = current()
    :all in roles or Enum.any?(required_roles, &(&1 in roles))
  end

  @spec parse(String.t()) :: [atom()]
  def parse(roles_str) when is_binary(roles_str) do
    roles_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_role!/1)
  end

  defp parse_role!("all"), do: :all

  defp parse_role!(role) do
    atom = Enum.find(@roles, &(Atom.to_string(&1) == role))

    if atom do
      atom
    else
      raise ArgumentError, "unknown ZAQ node role: #{inspect(role)}"
    end
  end
end
