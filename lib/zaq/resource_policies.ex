defmodule Zaq.ResourcePolicies do
  @moduledoc """
  Authorized internal resource-policy persistence primitives.

  This foundation is not an activated confidentiality system. It exposes no
  routed management API, default editor, or readiness override. Routed consumers must
  authorize policy visibility before exposing a row; an internal lookup is not
  an access grant. Resolution and enforcement are delivered in later increments.

  Administration requires the current BO User's role capabilities. People and
  Teams are policy subjects, never administrators; their portal/content grants
  and clearance levels cannot authorize policy reads or mutations. No policy
  operation creates administrative ResourcePermission grants or creation scopes.

  Data-source documents/folders own policy through their existing source-permission
  identities. Ingestion documents cannot own a competing override. This increment
  rejects their unresolved bindings and all source mutations until owner-verified
  source resolution is implemented; source coordinates alone do not prove existence.
  """

  alias Zaq.Accounts.BOAuthorization
  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.Repo
  alias Zaq.ResourcePolicies.ResourceRef

  @doc "False until the full enforcement deployment contract has been implemented."
  @spec ready?() :: false
  def ready?, do: false

  @doc """
  Looks up a registered target for internal security resolution, without exposing it.

  A valid target without a row returns `{:ok, nil}`. Invalid coordinates are errors.
  Repository failures propagate; they must never be mistaken for default policy.
  This lookup does not assert that the target still exists in its owning domain.
  It is not a hierarchy resolver: callers must establish verified source identity
  before lookup. An ingestion-document reference returns `:unresolved_source`,
  not an absent row/default policy.
  """
  @spec fetch(term()) ::
          {:ok, ResourcePolicy.t() | nil} | {:error, :invalid_resource | :unresolved_source}
  def fetch(resource) do
    with {:ok, {type, id}} <- ResourceRef.new(resource) do
      {:ok, Repo.get_by(ResourcePolicy, resource_type: type, resource_id: id)}
    end
  end

  @doc "Reads a policy only after its independent policy-view authorization."
  @spec read(term(), term()) :: {:ok, ResourcePolicy.t()} | {:error, term()}
  def read(actor, policy_id) do
    with {:ok, _user} <- BOAuthorization.authorize(actor, :view_resource_policies),
         {:ok, policy} <- policy_by_id(policy_id),
         {:ok, _ref} <- ResourceRef.new({policy.resource_type, policy.resource_id}) do
      {:ok, policy}
    end
  end

  @doc """
  Creates a policy under BO role authority, without creating ACL grants.

  Internal domain operation only: no routed Action or user-facing policy editor
  calls it in this increment. Subsequent external boundaries must additionally
  enforce deployment readiness. Add authority cannot overwrite an existing policy.
  Source mutations require owner verification, which is not provided by this
  foundation; neither a source UUID nor an ingestion row enables them.
  """
  @spec create(term(), term(), term()) :: {:ok, ResourcePolicy.t()} | {:error, term()}
  def create(actor, resource, attrs) when is_map(attrs) and not is_struct(attrs) do
    with {:ok, _user} <- BOAuthorization.authorize(actor, :add_resource_policies),
         {:ok, ref} <- ResourceRef.new(resource),
         :ok <- target_exists(ref) do
      %ResourcePolicy{}
      |> ResourcePolicy.changeset(policy_params(ref, attrs))
      |> Repo.insert()
      |> creation_result()
    end
  end

  def create(_, _, _), do: {:error, :invalid_request}

  @doc "Edits independent overrides with policy-edit authority and a required version."
  @spec update(term(), term(), term(), term()) :: {:ok, ResourcePolicy.t()} | {:error, term()}
  def update(actor, policy_id, expected_version, attrs)
      when is_map(attrs) and not is_struct(attrs) and is_integer(expected_version) do
    with {:ok, _user} <- BOAuthorization.authorize(actor, :edit_resource_policies),
         {:ok, policy} <- policy_by_id(policy_id),
         {:ok, ref} <- ResourceRef.new({policy.resource_type, policy.resource_id}),
         :ok <- target_exists(ref),
         true <- policy.lock_version == expected_version do
      policy
      |> ResourcePolicy.changeset(attrs)
      |> Repo.update(stale_error_field: :lock_version)
      |> edit_result()
    else
      false -> {:error, :conflict}
      {:error, _} = error -> error
    end
  end

  def update(_, _, _, _), do: {:error, :invalid_request}

  defp policy_params({type, id}, attrs) do
    attrs
    |> Map.drop([:resource_type, :resource_id, "resource_type", "resource_id"])
    |> Map.merge(%{resource_type: type, resource_id: id})
  end

  defp creation_result({:error, %Ecto.Changeset{} = changeset} = error) do
    if unique_target_error?(changeset), do: {:error, :already_exists}, else: error
  end

  defp creation_result(result), do: result

  defp unique_target_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique and
        metadata[:constraint_name] == "resource_policies_target_index"
    end)
  end

  defp edit_result({:error, %Ecto.Changeset{} = changeset} = error) do
    if Keyword.has_key?(changeset.errors, :lock_version), do: {:error, :conflict}, else: error
  end

  defp edit_result(result), do: result

  defp policy_by_id(id) do
    with {:ok, {"resource_policy", normalized}} <- ResourceRef.new({"resource_policy", id}),
         %ResourcePolicy{} = policy <- Repo.get(ResourcePolicy, normalized) do
      {:ok, policy}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp target_exists({type, "default"})
       when type in ["configured_agent", "ai_provider_credential"],
       do: :ok

  defp target_exists({_type, id} = ref) do
    with {:ok, schema} <- ResourceRef.target_schema(ref) do
      if Repo.get(schema, id), do: :ok, else: {:error, :not_found}
    end
  end
end
