defmodule Zaq.Accounts.BOAuthorization do
  @moduledoc """
  Shared capability evaluation for current BO User/Role authority.

  Actors must come from an authenticated event/session boundary. Only their User
  ID is used to reload current account and role state; supplied role, Person and
  bypass fields never grant authority. No User-to-Person linkage is required.
  Super administrators have all listed capabilities. Other roles may explicitly
  list delegated capabilities in `meta["permissions"]`, but cannot administer roles.
  Domain boundaries request a named capability here rather than duplicating
  role checks. Authentication belongs to BOActor; trusted execution-context
  issuance belongs to Events.TrustedContext, not this permission evaluator.
  """

  alias Zaq.Accounts.BOActor

  @delegated_capabilities [
    :view_resource_policies,
    :add_resource_policies,
    :edit_resource_policies,
    :manage_confidentiality_defaults,
    :skip_actor_clearance
  ]
  @operations [:manage_roles | @delegated_capabilities]

  @doc "Authorizes a named operation using current persisted role authority."
  @spec authorize(term(), atom()) :: {:ok, Zaq.Accounts.User.t()} | {:error, :unauthorized}
  def authorize(actor, operation) when operation in @operations do
    with {:ok, user} <- BOActor.current_user(actor),
         true <- permitted?(user.role, operation) do
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_, _), do: {:error, :unauthorized}

  defp permitted?(%{name: "super_admin"}, _), do: true

  defp permitted?(%{meta: meta}, operation)
       when is_map(meta) and operation in @delegated_capabilities do
    case Map.get(meta, "permissions") do
      permissions when is_list(permissions) -> Atom.to_string(operation) in permissions
      _ -> false
    end
  end

  defp permitted?(_, _), do: false
end
