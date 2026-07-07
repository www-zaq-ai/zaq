defmodule Zaq.Ingestion.ExternalPermissions do
  @moduledoc """
  Imports provider record permissions into ZAQ document permissions.
  """

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion

  require Logger

  @spec apply(Record.t(), [map() | struct()]) :: :ok
  def apply(%Record{} = record, documents) when is_list(documents) do
    record
    |> principals()
    |> Enum.each(fn principal ->
      with {:ok, person} <- ensure_person(record, principal),
           rights when rights != [] <- rights_for(principal) do
        Enum.each(
          documents,
          &Ingestion.set_document_permission(&1.id, :person, person.id, rights)
        )
      else
        {:error, reason} ->
          log_skipped_principal(record, principal, reason)

        [] ->
          log_skipped_principal(record, principal, :no_rights)
      end
    end)

    :ok
  end

  defp log_skipped_principal(%Record{} = record, principal, reason) do
    role = principal["role"] || principal[:role]

    Logger.warning(
      "Skipped external permission principal for record #{inspect(record.id)} " <>
        "from #{provider(record)}: #{inspect(reason)} role=#{inspect(role)}"
    )
  end

  defp principals(%Record{} = record) do
    owner_principals = Enum.map(record.owners || [], &Map.put(normalize_map(&1), "role", "owner"))
    permission_principals = Enum.map(record.permissions || [], &permission_principal/1)
    owner_principals ++ permission_principals
  end

  defp permission_principal(%Record{} = permission) do
    raw = normalize_map(permission.raw || %{})

    raw
    |> Map.put_new("id", permission.id)
    |> Map.put_new("display_name", permission.name)
    |> Map.put_new("email", raw["emailAddress"] || raw["email_address"] || permission.name)
  end

  defp permission_principal(permission), do: normalize_map(permission)

  defp ensure_person(%Record{} = record, principal) do
    case principal_identity(record, principal) do
      {:ok, channel_provider, channel_id, display_name, attrs} ->
        ensure_channel_person(channel_provider, channel_id, display_name, attrs)

      :error ->
        {:error, :unmappable_principal}
    end
  end

  defp principal_identity(%Record{} = record, principal) do
    email = principal["email"] || principal["emailAddress"] || principal["email_address"]
    id = principal["id"]
    display_name = principal["display_name"] || principal["displayName"] || email || id

    email_identity(email, display_name) || id_identity(provider(record), id, display_name) ||
      :error
  end

  defp email_identity(email, display_name) when is_binary(email) do
    if String.contains?(email, "@"), do: {:ok, "email", email, display_name, %{"email" => email}}
  end

  defp email_identity(_email, _display_name), do: nil

  defp id_identity(provider, id, display_name) when is_binary(id) and id != "",
    do: {:ok, provider, id, display_name, %{}}

  defp id_identity(_provider, _id, _display_name), do: nil

  defp ensure_channel_person(provider, channel_id, display_name, extra_attrs) do
    attrs =
      extra_attrs
      |> Map.put("channel_id", channel_id)
      |> Map.put("display_name", display_name)

    People.find_or_create_from_channel(provider, attrs)
  end

  defp rights_for(principal) do
    case principal["role"] || principal[:role] do
      role when role in ["owner", "writer", "organizer", "fileOrganizer"] -> ["read", "write"]
      role when role in ["reader", "commenter"] -> ["read"]
      _ -> ["read"]
    end
  end

  defp provider(%Record{attributes: attrs}) when is_map(attrs),
    do: attrs["provider"] || attrs[:provider]

  defp provider(_), do: "data_source"

  defp normalize_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_map(_), do: %{}
end
