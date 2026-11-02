defmodule Zaq.Engine.Actions.ManageLiveUpdateSettings do
  @moduledoc "Confidential authenticated BO Action for connector policies and atomic native connector edits."

  use Jido.Action,
    name: "manage_live_update_settings",
    description: "Read or save one exact connector's streamed-update policy",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.LiveUpdateSettings

  @impl Jido.Action
  def run(%{request: request}, context) do
    with {:ok, _user} <- BOActor.current_user(Map.get(context, :actor)) do
      {:ok, %{result: LiveUpdateSettings.execute(request)}}
    end
  end
end
