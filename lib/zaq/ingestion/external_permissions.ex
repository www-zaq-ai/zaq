defmodule Zaq.Ingestion.ExternalPermissions do
  @moduledoc """
  Imports canonical provider record permissions into ZAQ document permissions.

  Verified source Records and trusted Channels refreshes share the source key
  `source:` followed by the canonical document source. Complete permission lists
  reconcile only that source; `[]` revokes its grants and `nil` changes nothing.
  Manual sharing and other source grants remain independent. Authenticated
  permission principal/role/rights fields are authority; unsigned owners, raw
  provider payloads and display names are not. Canonical `edit` maps to document
  `update`; move/create never imply update and write remains write.

  Projection locks matching persisted Documents and checks every permission write
  in one transaction. Callers composing further writes must propagate errors into
  their outer transaction. Unsigned compatibility records may affect only genuine
  non-source Documents; they can never prune canonical source grants.
  """

  alias Zaq.Accounts.People
  alias Zaq.Channels.Events, as: ChannelEvents
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Events.TrustedContext
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, ExternalSource}
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  import Ecto.Query

  require Logger

  @spec apply(Record.t(), [map() | struct()]) :: :ok | {:error, term()}
  def apply(%Record{} = record, documents) when is_list(documents) do
    with {:ok, scope, record} <- source_scope(record) do
      project(record, documents, scope)
    end
  end

  @doc "Refreshes matching source Documents from a trusted Channels permission snapshot."
  @spec refresh(map(), [struct()], map()) :: :ok | {:error, term()}
  def refresh(%{provider: provider, config_id: config_id, record_id: id}, documents, context)
      when is_binary(provider) and provider != "" and is_binary(id) and id != "" do
    case ParseUtils.parse_int_strict(config_id) do
      {:ok, value} when value > 0 -> refresh_source(provider, value, id, documents, context)
      _ -> {:error, :invalid_source_record}
    end
  end

  def refresh(_reference, _documents, _context), do: {:error, :invalid_source_record}

  @doc "Clears only a confirmed mutation's failed source projection; never manual sharing."
  @spec invalidate_after_mutation(map(), [struct()], map()) :: :ok | {:error, term()}
  def invalidate_after_mutation(reference, documents, context) do
    if Map.get(context, :source_acl_mutation_committed) == true and
         is_map(Map.get(context, :actor)) do
      invalidate_source(reference, documents)
    else
      {:error, :unconfirmed_source_mutation}
    end
  end

  defp invalidate_source(%{provider: provider, config_id: config_id, record_id: id}, documents) do
    case ParseUtils.parse_int_strict(config_id) do
      {:ok, config_id} when config_id > 0 ->
        record = %Record{
          id: id,
          kind: :file,
          permissions: [],
          attributes: %{"provider" => provider, "config_id" => config_id}
        }

        project(record, documents, ExternalSource.source(record))

      _ ->
        {:error, :invalid_source_record}
    end
  end

  defp refresh_source(provider, config_id, id, documents, context) do
    params = %{"config_id" => to_string(config_id), "file_id" => id}

    response =
      ChannelEvents.build_and_dispatch_data_source_list_permissions_event(
        provider,
        params,
        TrustedContext.event_builder_opts(context)
      ).response

    with {:ok, permissions} <- permission_snapshot(response) do
      record = %Record{
        id: id,
        kind: :file,
        permissions: permissions,
        attributes: %{"provider" => provider, "config_id" => config_id}
      }

      project(record, documents, ExternalSource.source(record))
    end
  end

  defp permission_snapshot({:ok, %{pagination: %{has_more?: true}}}),
    do: {:error, :incomplete_permissions}

  defp permission_snapshot({:ok, %{pagination: %{truncated?: true}}}),
    do: {:error, :incomplete_permissions}

  defp permission_snapshot({:ok, %{records: permissions}}) when is_list(permissions),
    do: {:ok, permissions}

  defp permission_snapshot({:error, _} = error), do: error
  defp permission_snapshot(_), do: {:error, :invalid_permission_snapshot}

  defp source_scope(record) do
    case Provenance.verify(record) do
      {:ok, claims} ->
        verified_source_scope(record, claims)

      {:error, :missing_record_provenance} ->
        {:ok, :legacy, record}

      {:error, _} ->
        {:error, :invalid_source_record}
    end
  end

  defp verified_source_scope(record, %{
         "provider" => provider,
         "config_id" => config_id,
         "provider_record_id" => id
       })
       when is_binary(provider) and provider not in ["", "local"] and not is_nil(config_id) and
              is_binary(id) and id != "" do
    canonical = %{
      record
      | attributes:
          Map.merge(
            record.attributes || %{},
            %{"provider" => provider, "config_id" => config_id, "provider_record_id" => id}
          )
    }

    {:ok, ExternalSource.source(canonical), canonical}
  end

  defp verified_source_scope(record, _claims), do: {:ok, :legacy, record}

  defp project(record, documents, scope) do
    Repo.transaction(fn ->
      if scope != :legacy and not (is_list(record.permissions) or is_nil(record.permissions)),
        do: Repo.rollback(:invalid_permission_snapshot)

      documents = lock_documents!(documents, scope)
      desired = desired_permissions(record, scope)
      Enum.each(documents, &project_document!(&1, desired, record, scope))
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_documents!(documents, scope) do
    ids = Enum.map(documents, & &1.id) |> Enum.uniq() |> Enum.sort()

    documents =
      Repo.all(from d in Document, where: d.id in ^ids, order_by: d.id, lock: "FOR UPDATE")

    if length(documents) != length(ids), do: Repo.rollback(:not_found)

    Enum.each(documents, &validate_document_source!(&1, scope))

    documents
  end

  defp validate_document_source!(document, :legacy) do
    if String.starts_with?(document.source, "data_source/"),
      do: Repo.rollback(:invalid_source_record)
  end

  defp validate_document_source!(document, source) do
    if document.source != source, do: Repo.rollback(:source_mismatch)
  end

  defp project_document!(document, desired, record, :legacy) do
    Enum.each(desired, fn {type, id, rights} ->
      case Ingestion.set_document_permission(document.id, type, id, rights) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    if complete_snapshot?(record), do: prune_stale_permissions(document.id, desired)
  end

  defp project_document!(document, desired, record, source) do
    source_key = "source:" <> source

    grants =
      Enum.map(desired, fn {type, id, rights} ->
        Map.put(%{access_rights: rights}, if(type == :person, do: :person_id, else: :team_id), id)
      end)

    result =
      if complete_snapshot?(record) do
        Permissions.replace_source(document, source_key, grants)
      else
        {:ok, []}
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp desired_permissions(record, scope) do
    desired = Enum.flat_map(principals(record, scope), &principal_grant(record, &1, scope))

    if scope == :legacy do
      Enum.uniq_by(desired, fn {type, id, _rights} -> {type, id} end)
    else
      desired
      |> Enum.group_by(fn {type, id, _rights} -> {type, id} end, &elem(&1, 2))
      |> Enum.map(fn {{type, id}, rights} ->
        {type, id, rights |> List.flatten() |> Enum.uniq() |> Enum.sort()}
      end)
      |> Enum.sort()
    end
  end

  defp principal_grant(record, principal, scope) do
    with {:ok, rights} <- document_rights(principal, scope),
         false <- rights == [],
         {:ok, target_type, target_id} <- ensure_target(record, principal) do
      [{target_type, to_string(target_id), rights}]
    else
      true ->
        log_skipped_principal(record, principal, :no_rights)
        []

      {:error, reason} ->
        if scope == :legacy do
          log_skipped_principal(record, principal, reason)
          []
        else
          Repo.rollback({:permission_projection_failed, reason})
        end
    end
  end

  defp document_rights(principal, :legacy), do: {:ok, rights_for(principal)}

  defp document_rights(principal, _source) do
    rights = rights_for(principal)

    if Enum.all?(rights, &(&1 in ~w(read write update delete edit manage move create))) do
      {:ok,
       rights
       |> Enum.reject(&(&1 in ["move", "create"]))
       |> Enum.map(fn
         "edit" -> "update"
         right -> right
       end)
       |> Enum.uniq()}
    else
      {:error, :unsupported_access_rights}
    end
  end

  defp complete_snapshot?(%Record{permissions: permissions}) when is_list(permissions), do: true
  defp complete_snapshot?(_record), do: false

  defp prune_stale_permissions(document_id, desired) do
    desired_keys = MapSet.new(desired, fn {type, target_id, _rights} -> {type, target_id} end)

    document_id
    |> Ingestion.list_document_permissions()
    |> Enum.reject(fn permission -> permission_key(permission) in desired_keys end)
    |> Enum.each(fn permission ->
      case Ingestion.delete_document_permission(permission.id) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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

  defp principals(record, scope) when scope != :legacy do
    case Provenance.permission_projection(record.permissions) do
      %{"entries" => entries} when is_list(entries) -> Enum.map(entries, &permission_principal/1)
      _ -> []
    end
  end

  defp principals(%Record{} = record, :legacy) do
    owner_principals = Enum.map(record.owners || [], &Map.put(normalize_map(&1), "role", "owner"))
    permission_principals = Enum.map(record.permissions || [], &permission_principal/1)
    owner_principals ++ permission_principals
  end

  defp permission_principal(
         %{"principal" => %{"type" => type, "key" => key}, "rights" => rights} = entry
       ) do
    principal = %{"type" => type, "id" => key, "role" => entry["role"], "access_rights" => rights}

    cond do
      type in ["person", "team"] ->
        Map.put(principal, "target_id", key)

      type in ["user", "email"] and is_binary(key) and String.contains?(key, "@") ->
        Map.put(principal, "email", key)

      type == "public" ->
        principal

      true ->
        Map.put(principal, "target_id", key)
    end
  end

  defp permission_principal(%Record{} = permission) do
    raw =
      Map.merge(normalize_map(permission.raw || %{}), normalize_map(permission.attributes || %{}))

    raw
    |> Map.put_new("id", permission.id)
    |> Map.put_new("display_name", permission.name)
    |> Map.put_new("email", raw["emailAddress"] || raw["email_address"] || permission.name)
  end

  defp permission_principal(permission), do: normalize_map(permission)

  defp ensure_target(%Record{} = _record, %{"type" => "public"}) do
    {:ok, :team, Permissions.everyone_team_id()}
  end

  defp ensure_target(%Record{} = _record, %{"type" => "person", "target_id" => target_id})
       when is_binary(target_id) and target_id != "" do
    {:ok, :person, target_id}
  end

  defp ensure_target(%Record{} = _record, %{"type" => "team", "target_id" => target_id})
       when is_binary(target_id) and target_id != "" do
    {:ok, :team, target_id}
  end

  defp ensure_target(
         %Record{} = _record,
         %{"type" => type, "target_id" => target_id}
       )
       when is_binary(type) and type != "" and type not in ["person", "team"] and
              is_binary(target_id) and target_id != "" do
    {:error, :unsupported_target_type}
  end

  defp ensure_target(%Record{} = record, principal) do
    case principal_identity(record, principal) do
      {:ok, channel_provider, channel_id, display_name, attrs} ->
        with {:ok, person} <-
               ensure_contact_person(channel_provider, channel_id, display_name, attrs) do
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

  defp ensure_contact_person(provider, channel_id, display_name, extra_attrs) do
    attrs =
      extra_attrs |> Map.put("channel_id", channel_id) |> Map.put("display_name", display_name)

    case People.match_person(Map.take(attrs, ["email"])) do
      {:ok, person} -> {:ok, person}
      {:error, :not_found} -> People.find_or_create_from_channel(provider, attrs)
      {:error, _} = error -> error
    end
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
