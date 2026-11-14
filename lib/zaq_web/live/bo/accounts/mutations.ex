defmodule ZaqWeb.Live.BO.Accounts.Mutations do
  @moduledoc """
  Thin BO transport for guarded account-role mutations.

  The authenticated socket supplies current User identity, never form fields.
  Engine and Accounts reload authority; this adapter makes no permission decision.
  """

  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Dispatches a declared account mutation with a confidential envelope."
  def run(current_user, operation, params) when is_atom(operation) and is_map(params) do
    actor = if current_user, do: %{user_id: current_user.id}

    Event.new(%{operation: operation, params: params}, :engine,
      actor: actor,
      opts: [action: :account_administration, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
