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
          permission_projection: map()
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
  @spec identity(Record.t()) :: {:ok, identity()} | {:error, :invalid_source_record}
  def identity(%Record{kind: :file, attributes: attrs} = record) when is_map(attrs) do
    with {:ok,
          %{
            "provider" => provider,
            "config_id" => config_id,
            "provider_record_id" => file_id,
            "permissions" => projection
          }} <-
           Provenance.verify(record),
         true <- is_binary(provider) and provider not in ["", "local"],
         true <- is_integer(config_id) or is_binary(config_id),
         true <- is_binary(file_id) and file_id != "",
         ^provider <- ExternalSource.provider(record),
         true <- config_matches?(attrs, config_id),
         ^file_id <- ExternalSource.file_id(record) do
      {:ok, %{source: ExternalSource.source(record), permission_projection: projection}}
    else
      _ -> {:error, :invalid_source_record}
    end
  end

  def identity(_record), do: {:error, :invalid_source_record}

  defp config_matches?(attrs, signed_id) do
    case Map.get(attrs, "config_id") || Map.get(attrs, :config_id) do
      id when is_integer(id) or is_binary(id) -> to_string(id) == to_string(signed_id)
      _ -> false
    end
  end
end
