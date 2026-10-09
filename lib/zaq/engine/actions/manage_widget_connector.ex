defmodule Zaq.Engine.Actions.ManageWidgetConnector do
  @moduledoc "Confidential BO Action for scoped widget configuration and key management."

  @schema Zoi.object(%{request: Zoi.any()})
  @output_schema Zoi.object(%{result: Zoi.any()})

  use Jido.Action,
    name: "manage_widget_connector",
    description: "Manage one exact web widget connector",
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.WidgetConnectorSettings

  @impl Jido.Action
  def run(%{request: request}, context) do
    with {:ok, _user} <- BOActor.current_user(Map.get(context, :actor)) do
      {:ok, %{result: WidgetConnectorSettings.execute(request, Map.get(context, :opts, []))}}
    end
  end
end
