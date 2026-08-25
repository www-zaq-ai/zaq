defmodule Zaq.Ingestion.ExternalPermissions do
  @moduledoc """
  Imports canonical provider record permissions into ZAQ document permissions.
  """

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion

  require Logger

  @spec apply(Record.t(), [map() | struct()]) :: :ok
  def apply(%Record{} = record, documents) when is_list(documents) do
    desired = desired_permissions(record)

    Enum.each(documents, fn document ->
      Enum.each(desired, fn {target_type, target_id, rights} ->
        Ingestion.set_document_permission(document.id, target_type, target_id, rights)
      end)

      if complete_snapshot?(record) do
        prune_stale_permissions(document.id, desired)
      end
    end)

    :ok
  end

  defp desired_permissions(%Record{} = record) do
    record
    |> principals()
    |> Enum.flat_map(fn principal ->
      with {:ok, target_type, target_id} <- ensure_target(record, principal),
           rights when rights != [] <- rights_for(principal) do
        [{target_type, to_string(target_id), rights}]
      else
        {:error, reason} ->
          log_skipped_principal(record, principal, reason)
          []

        [] ->
          log_skipped_principal(record, principal, :no_rights)
          []
      end
    end)
    |> Enum.uniq_by(fn {target_type, target_id, _rights} -> {target_type, target_id} end)
  end

  defp complete_snapshot?(%Record{permissions: permissions}) when is_list(permissions), do: true
  defp complete_snapshot?(_record), do: false

  defp prune_stale_permissions(document_id, desired) do
    desired_keys = MapSet.new(desired, fn {type, target_id, _rights} -> {type, target_id} end)

    document_id
    |> Ingestion.list_document_permissions()
    |> Enum.reject(fn permission -> permission_key(permission) in desired_keys end)
    |> Enum.each(&Ingestion.delete_document_permission(&1.id))
  end

  defp permission_key(%{person_id: person_id}) when not is_nil(person_id),
    do: {:person, to_string(person_id)}

  defp permission_key(%{team_id: team_id}) when not is_nil(team_id),
    do: {:team, to_string(team_id)}

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

  defp ensure_target(%Record{} = _record, %{"type" => type, "target_id" => target_id})
       when type in ["person", "team"] and is_binary(target_id) and target_id != "" do
    {:ok, String.to_existing_atom(type), target_id}
  rescue
    ArgumentError -> {:error, :unsupported_target_type}
  end

  defp ensure_target(%Record{} = record, principal) do
    case principal_identity(record, principal) do
      {:ok, channel_provider, channel_id, display_name, attrs} ->
        with {:ok, person} <-
               ensure_channel_person(channel_provider, channel_id, display_name, attrs) do
          {:ok, :person, person.id}
        end

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
    case principal["access_rights"] || principal[:access_rights] do
      rights when is_list(rights) -> Enum.map(rights, &to_string/1)
      _ -> rights_for_role(principal)
    end
  end

  defp rights_for_role(principal) do
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
