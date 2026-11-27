defmodule Zaq.Ingestion.ChunkRefreshSource do
  @moduledoc """
  Verifies the source and permission projection for an index refresh.
  Only the Ingestion role can use a revalidated Back Office super admin to
  refresh the index. A signed Record establishes identity, not write authority.
  """

  alias Zaq.Accounts.{BOActor, User}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion.ExternalSource

  @type identity :: %{
          source: String.t(),
          permission_projection: map(),
          record: Record.t()
        }

  @doc "Returns the currently authorized Back Office super admin."
  @spec authorize(map() | nil) :: {:ok, User.t()} | {:error, :unauthorized}
  def authorize(actor) do
    case BOActor.current_user(actor) do
      {:ok, %User{role: %{name: "super_admin"}} = user} -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Derives the source and permission projection from authenticated Record claims."
  @spec identity(map()) :: {:ok, identity()} | {:error, :invalid_source_record}
  def identity(record) when is_map(record) do
    ref = Map.get(record, :provenance_ref) || Map.get(record, "provenance_ref")

    with {:ok,
          %{
            "provider" => provider,
            "config_id" => config_id,
            "provider_record_id" => file_id,
            "kind" => "file",
            "source_metadata" => metadata,
            "permissions" => projection
          } = claims} <-
           Provenance.verify_ref(ref),
         true <- is_binary(provider) and provider not in ["", "local"],
         true <- is_integer(config_id) or is_binary(config_id),
         true <- is_binary(file_id) and file_id != "" do
      source = %Record{
        id: file_id,
        kind: :file,
        name: metadata["name"],
        mime_type: metadata["mime_type"],
        url: metadata["url"],
        parent_id: claims["parent_id"],
        parent_ids: metadata["parent_ids"] || [],
        attributes: %{"provider" => provider, "config_id" => config_id}
      }

      {:ok,
       %{source: ExternalSource.source(source), permission_projection: projection, record: source}}
    else
      _ -> {:error, :invalid_source_record}
    end
  end

  def identity(_record), do: {:error, :invalid_source_record}
end
