defmodule Zaq.Channels.Actions.PairLinkedDevice do
  @moduledoc """
  Confidential operator Action for adapter authentication; never an agent tool.

  Normalized `command` requests implement `Zaq.SignIn` and derive session ownership
  from the trusted BO session actor, never from client-supplied owner identity.
  Super-admin authorization arrives in execution context, not request fields.
  """
  use Jido.Action,
    name: "pair_linked_device",
    description: "Pair and confirm a linked device before creating its connector",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Channels.CommunicationBridge

  def run(
        %{request: %{provider: provider} = request},
        %{actor: %{user_id: id} = actor, confidential: true, skip_permissions: true} = context
      )
      when is_integer(id) and id > 0 do
    opts = Keyword.put(Map.get(context, :bridge_opts, []), :skip_permissions, true)
    {:ok, %{result: authenticate(request, provider, id, actor, opts)}}
  end

  def run(_, _), do: {:error, :unauthorized}

  defp authenticate(%{command: command}, provider, id, actor, opts),
    do:
      CommunicationBridge.sign_in(
        command,
        %{provider: provider, owner_id: id, actor: actor},
        opts
      )

  defp authenticate(_, _, _, _, _), do: {:error, :invalid_request}
end
