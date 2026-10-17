defmodule Zaq.Engine.Actions.DisableChannelConnector do
  @moduledoc "Confidential administrator Action for confirmed connector disable and logout."

  use Jido.Action,
    name: "disable_channel_connector",
    description: "Prepare or execute a scoped connector disable with adapter logout",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.ConnectorLifecycle

  @impl Jido.Action
  def run(%{request: request}, %{actor: actor, confidential: true} = context) do
    case BOActor.current_user(actor) do
      {:ok, %{role: %{name: "super_admin"}}} ->
        {:ok, %{result: execute(request, actor, Map.get(context, :opts, []))}}

      _ ->
        {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}

  defp execute(%{op: :context, channel_config_id: id, provider: provider, kind: kind}, _, _),
    do: ConnectorLifecycle.context(id, provider, kind)

  defp execute(%{op: :disable} = request, actor, opts),
    do: ConnectorLifecycle.disable(request, actor, opts)

  defp execute(_, _, _), do: {:error, :invalid_request}
end
