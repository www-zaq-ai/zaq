defmodule Zaq.ResourcePolicies.ResourceRef do
  @moduledoc """
  Canonical, allowlisted resource-policy target coordinates.

  Reuses ResourcePermission type names, not the aliases in the agent query tool.
  Coordinates identify targets; they neither prove existence nor grant access.
  Data-source documents and folders reuse their source owner's permission target:
  mounted Storage entries use StorageEntry with a stable catalog UUID, regardless
  of ingestion. Kind, provider/configuration scope, existence and ancestry remain
  owner-verified facts, not claims inferred from a path or from this validator.

  An Ingestion.Document is derived content, not a separately editable policy
  target. Resolving its verified source binding and supporting additional source
  owners belongs to the subsequent resolver increment. Unresolved document
  references are errors, never an unset/default policy or an ingestion-id fallback.
  """

  @modules %{
    Zaq.Agent.ConfiguredAgent => "configured_agent",
    Zaq.System.AIProviderCredential => "ai_provider_credential",
    Zaq.Agent.MCP.Endpoint => "endpoint",
    Zaq.Accounts.Person => "person",
    Zaq.Accounts.Team => "team",
    Zaq.Engine.ChannelConfig => "channel_config",
    Zaq.Engine.RetrievalChannel => "retrieval_channel",
    Zaq.Engine.Workflows.Workflow => "workflow",
    Zaq.Permissions.ResourcePolicy => "resource_policy"
  }
  @types Map.values(@modules)
  @max_id 9_223_372_036_854_775_807

  @type t :: {String.t(), String.t()}

  @doc "Validates and normalizes registered struct or tuple coordinates."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_resource | :unresolved_source}
  def new(%Zaq.Ingestion.Document{id: id}), do: new({"document", id})
  def new(%Zaq.Storage.StorageEntry{id: id}), do: new({"storage_entry", id})

  def new(%{__struct__: module, id: id}) do
    case Map.fetch(@modules, module) do
      {:ok, type} -> new({type, id})
      :error -> invalid()
    end
  end

  def new({"document", id}) do
    case numeric_id(id) do
      {:ok, _id} -> {:error, :unresolved_source}
      :error -> invalid()
    end
  end

  def new({"storage_entry", id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} when byte_size(id) == 36 -> {:ok, {"storage_entry", id}}
      _ -> invalid()
    end
  end

  def new({type, "default"}) when type in ["configured_agent", "ai_provider_credential"],
    do: {:ok, {type, "default"}}

  def new({type, id}) when type in @types do
    case numeric_id(id) do
      {:ok, normalized} -> {:ok, {type, normalized}}
      :error -> invalid()
    end
  end

  def new(_), do: invalid()

  @doc "Returns an allowlisted native target schema; source existence stays with its owner."
  @spec target_schema(t()) :: {:ok, module()} | {:error, :unresolved_source}
  def target_schema({type, _id}) do
    case Enum.find(@modules, fn {_module, registered_type} -> registered_type == type end) do
      {module, _type} -> {:ok, module}
      nil -> {:error, :unresolved_source}
    end
  end

  @doc "Stable policy identity for the default answering configuration."
  @spec default_agent() :: t()
  def default_agent, do: {"configured_agent", "default"}

  @doc "Stable policy identity for an explicitly selected built-in provider configuration."
  @spec default_provider() :: t()
  def default_provider, do: {"ai_provider_credential", "default"}

  defp numeric_id(id) when is_integer(id) and id > 0 and id <= @max_id,
    do: {:ok, Integer.to_string(id)}

  defp numeric_id(id) when is_binary(id) and byte_size(id) <= 19 do
    case Integer.parse(id) do
      {integer, ""} when integer > 0 and integer <= @max_id ->
        if Integer.to_string(integer) == id, do: {:ok, id}, else: :error

      _ ->
        :error
    end
  end

  defp numeric_id(_), do: :error

  defp invalid, do: {:error, :invalid_resource}
end
