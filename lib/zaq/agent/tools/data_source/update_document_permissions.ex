defmodule Zaq.Agent.Tools.DataSource.UpdateDocumentPermissions do
  @moduledoc """
  Incrementally updates direct permissions on a loaded data-source file or folder.

  The Action delegates to Channels, where the provider bridge owns the mutation.
  Disk permission writes are handled by Storage; Ingestion only receives the
  resulting projection-sync notification. Inherited and unmentioned direct grants
  are preserved.
  """

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.Record

  @permission_types ["person", "team", "public"]
  @access_rights Zaq.Permissions.ResourcePermission.valid_rights()

  @grant_schema Zoi.object(%{
                  type: Zoi.enum(@permission_types, description: "Principal type."),
                  target_id:
                    Zoi.string(description: "Person or team id; omit for public access.")
                    |> Zoi.optional(),
                  access_rights:
                    Zoi.list(Zoi.enum(@access_rights),
                      description: "Direct access rights to grant."
                    )
                })
                |> Zoi.refine({__MODULE__, :validate_grant, []})

  @revocation_schema Zoi.object(%{
                       type: Zoi.enum(@permission_types, description: "Principal type."),
                       target_id:
                         Zoi.string(description: "Person or team id; omit for public access.")
                         |> Zoi.optional()
                     })
                     |> Zoi.refine({__MODULE__, :validate_principal, []})

  @schema Zoi.object(%{
            record:
              Record.zoi_type(
                description: "Loaded data-source file or folder whose ACL will change."
              ),
            grants:
              Zoi.list(@grant_schema, description: "Direct grants to add or update.")
              |> Zoi.optional(),
            revocations:
              Zoi.list(@revocation_schema, description: "Direct principals to revoke.")
              |> Zoi.optional()
          })
          |> Zoi.refine({__MODULE__, :validate_changes, []})

  @output_schema Zoi.object(
                   %{
                     status: Zoi.string(description: "Operation status."),
                     file_id: Zoi.string(description: "Provider file or folder id."),
                     affected_file_ids:
                       Zoi.list(Zoi.string(),
                         description: "Target and descendant ids whose effective ACL changed."
                       )
                   },
                   unrecognized_keys: :preserve
                 )

  use Zaq.Engine.Workflows.Action,
    name: "update_document_permissions",
    description:
      "Add, update, or revoke direct permissions on a loaded data-source file or folder while preserving inherited and unrelated grants.",
    schema: @schema,
    output_schema: @output_schema

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{record: %Record{} = record} = params, context) do
    grants = Map.get(params, :grants, [])
    revocations = Map.get(params, :revocations, [])

    DataSourceTool.dispatch(
      :data_source_update_permissions,
      %{
        record: record,
        changes: %{"grants" => grants, "revocations" => revocations}
      },
      context,
      "Data source permission update failed"
    )
  end

  def run(%{record: _other}, _context), do: {:error, {:invalid_input, :expected_record}}
  def run(_params, _context), do: {:error, {:invalid_input, :expected_record}}

  @doc "Validates one direct grant after schema conversion."
  def validate_grant(grant, opts) do
    with :ok <- validate_principal(grant, opts),
         rights when rights != [] <- Map.get(grant, :access_rights, []),
         :ok <- validate_public_rights(grant.type, rights) do
      :ok
    else
      [] -> {:error, "access_rights must not be empty"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Validates the target identity requirements for one principal command."
  def validate_principal(%{type: "public"} = principal, _opts) do
    if Map.get(principal, :target_id) in [nil, ""],
      do: :ok,
      else: {:error, "public permissions must not include target_id"}
  end

  def validate_principal(%{type: type} = principal, _opts) when type in ["person", "team"] do
    case Map.get(principal, :target_id) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {id, ""} when id > 0 -> :ok
          _other -> {:error, "#{type} target_id must be a positive integer"}
        end

      _other ->
        {:error, "#{type} permissions require target_id"}
    end
  end

  @doc "Validates that the command is nonempty and has no grant/revoke conflicts."
  def validate_changes(params, _opts) do
    grants = Map.get(params, :grants, [])
    revocations = Map.get(params, :revocations, [])

    cond do
      grants == [] and revocations == [] ->
        {:error, "at least one grant or revocation is required"}

      conflicting_principals?(grants, revocations) ->
        {:error, "the same principal cannot be granted and revoked"}

      true ->
        :ok
    end
  end

  defp conflicting_principals?(grants, revocations) do
    grant_keys = MapSet.new(grants, &principal_key/1)
    revocation_keys = MapSet.new(revocations, &principal_key/1)
    not MapSet.disjoint?(grant_keys, revocation_keys)
  end

  defp principal_key(%{type: type, target_id: target_id}), do: {type, target_id}
  defp principal_key(%{type: type}), do: {type, nil}

  defp validate_public_rights("public", ["read"]), do: :ok

  defp validate_public_rights("public", _rights),
    do: {:error, "public permissions support read access only"}

  defp validate_public_rights(_type, _rights), do: :ok
end
