defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectHelpers do
  @moduledoc """
  Pure helpers for Connect credential param normalization.
  """

  alias Zaq.Utils.Map, as: MapUtils
  alias Zaq.Utils.Scopes

  def sanitize_credential_params(params) when is_map(params) do
    params
    |> Map.drop(["provider", "request_format"])
    |> Map.update("scopes", [], &parse_scope_list/1)
    |> Map.update("metadata", %{}, &sanitize_metadata/1)
  end

  def sanitize_credential_params(_), do: %{"scopes" => []}

  def parse_scope_list(nil), do: []

  def parse_scope_list(scopes) when is_list(scopes) do
    Scopes.normalize(scopes)
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

  defp sanitize_metadata(metadata) when is_map(metadata) do
    profile = MapUtils.read_any(metadata, ["auth_profile_id", :auth_profile_id])
    subject = MapUtils.read_any(metadata, ["subject", :subject])

    %{}
    |> maybe_put("auth_profile_id", profile)
    |> maybe_put("subject", normalize_subject(subject))
  end

  defp sanitize_metadata(_), do: %{}

  defp normalize_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_subject(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
