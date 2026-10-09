defmodule Zaq.Engine.Workflows.Actions.ArchiveChannelConnector do
  @moduledoc """
  Administrator-only workflow Action for the complete connector archive command.

  Actor identity comes from trusted execution context and is never accepted as
  an Action input.
  """

  @schema Zoi.object(%{
            channel_config_id: Zoi.integer(),
            provider: Zoi.string(),
            kind: Zoi.string()
          })
  @output_schema Zoi.object(%{result: Zoi.map()})

  use Zaq.Engine.Workflows.Action,
    name: "archive_channel_connector",
    description: "Archive one exactly scoped channel connector",
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.ConnectorLifecycle

  @impl Jido.Action
  def run(params, context) when is_map(params) and is_map(context) do
    actor = Map.get(context, :actor)

    with {:ok, _user} <- BOActor.current_user(actor),
         {:ok, result} <- ConnectorLifecycle.archive(params, actor, Map.get(context, :opts, [])) do
      {:ok, %{result: result}}
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}
end
