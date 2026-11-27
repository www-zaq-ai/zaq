defmodule Zaq.Ingestion.ChunkRefreshSource do
  @moduledoc """
  Resolves the source and current permission projection for an index refresh.
  Only the Ingestion role can use a revalidated Back Office super admin to
  refresh the index. A signed Record establishes identity, not write authority.
  """

  alias Zaq.Accounts.{BOActor, User}
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion.ExternalSource
  alias Zaq.NodeRouter

  @type identity :: %{
          provider: String.t(),
          config_id: String.t(),
          file_id: String.t(),
          source: String.t()
        }

  @doc "Returns the currently authorized Back Office super admin."
  @spec authorize(map() | nil) :: {:ok, User.t()} | {:error, :unauthorized}
  def authorize(actor) do
    case BOActor.current_user(actor) do
      {:ok, %User{role: %{name: "super_admin"}} = user} -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Derives the canonical source from signed provider, configuration and file identity."
  @spec identity(Record.t()) :: {:ok, identity()} | {:error, :invalid_source_record}
  def identity(%Record{kind: :file, attributes: attrs} = record) when is_map(attrs) do
    with {:ok,
          %{"provider" => provider, "config_id" => config_id, "provider_record_id" => file_id}} <-
           Provenance.verify(record),
         true <- is_binary(provider) and provider not in ["", "local"],
         true <- is_integer(config_id) or is_binary(config_id),
         true <- is_binary(file_id) and file_id != "",
         ^provider <- ExternalSource.provider(record),
         true <- config_matches?(attrs, config_id),
         ^file_id <- ExternalSource.file_id(record) do
      config_id = to_string(config_id)

      {:ok,
       %{
         provider: provider,
         config_id: config_id,
         file_id: file_id,
         source: ExternalSource.source(record)
       }}
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

  @doc "Fetches current source metadata and effective permissions, without downloading content."
  @spec fetch(identity(), User.t(), map()) :: {:ok, Record.t()} | {:error, :source_unavailable}
  def fetch(identity, %User{} = user, context) do
    with {:ok, %{record: %Record{} = record}} <-
           dispatch(identity, :data_source_get_file, user, context),
         {:ok, ^identity} <- identity(record),
         {:ok, permissions} <- permissions(record, identity, user, context) do
      {:ok, %{record | permissions: permissions}}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp permissions(_record, %{provider: "disk"} = identity, user, context) do
    case dispatch(identity, :data_source_list_permissions, user, context) do
      {:ok, %RecordPage{records: records}} when is_list(records) -> {:ok, records}
      _ -> {:error, :source_unavailable}
    end
  end

  defp permissions(%Record{permissions: permissions}, _identity, _user, _context)
       when is_list(permissions),
       do: {:ok, permissions}

  defp permissions(_record, _identity, _user, _context), do: {:error, :source_unavailable}

  defp dispatch(identity, action, user, context) do
    params = %{
      "config_id" => identity.config_id,
      "file_id" => identity.file_id,
      "include_permissions" => true
    }

    actor = %{provider: "bo", user_id: user.id, skip_permissions: true}

    event =
      Event.new(%{provider: identity.provider, params: params}, :channels,
        actor: actor,
        opts: [action: action, confidential: true, skip_permissions: true]
      )

    router = context[:node_router] || NodeRouter
    router.dispatch(event).response
  end
end
