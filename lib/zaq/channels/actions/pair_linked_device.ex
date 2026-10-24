defmodule Zaq.Channels.Actions.PairLinkedDevice do
  @moduledoc "Confidential operator Action for adapter authentication; never an agent tool."
  use Jido.Action,
    name: "pair_linked_device",
    description: "Pair and confirm a linked device before creating its connector",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Accounts.BOActor
  alias Zaq.Channels.CommunicationBridge

  def run(
        %{request: %{provider: provider, op: _} = request},
        %{actor: actor, confidential: true} = context
      ) do
    case BOActor.current_super_admin(actor) do
      {:ok, %{id: id}} ->
        {:ok,
         %{
           result:
             CommunicationBridge.authenticate(
               provider,
               request,
               id,
               actor,
               Map.get(context, :bridge_opts, [])
             )
         }}

      _ ->
        {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}
end
