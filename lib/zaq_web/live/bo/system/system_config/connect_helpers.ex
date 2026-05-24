defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectHelpers do
  @moduledoc """
  Pure helpers for Connect credential param normalization.
  """

  def sanitize_credential_params(params) when is_map(params) do
    params
    |> Map.drop(["provider", "request_format"])
    |> Map.update("scopes", [], &parse_scope_list/1)
  end

  def sanitize_credential_params(_), do: %{"scopes" => []}

  def parse_scope_list(nil), do: []

  def parse_scope_list(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_scope_list(scopes) when is_binary(scopes) do
    scopes
    |> String.replace("\n", ",")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_scope_list(_), do: []
end
