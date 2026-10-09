defmodule Zaq.Engine.Actions.SaveEmailConnector do
  @moduledoc "Confidential BO Action for exact IMAP/SMTP connector persistence."

  @schema Zoi.object(%{
            provider: Zoi.string(),
            selected_config_id: Zoi.any(),
            params: Zoi.any()
          })
  @output_schema Zoi.object(%{result: Zoi.any()})

  use Jido.Action,
    name: "save_email_connector",
    description: "Save one exact email connector",
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.EmailConnectorSettings

  @impl Jido.Action
  def run(params, context) when is_map(params) and is_map(context) do
    actor = Map.get(context, :actor)

    case BOActor.current_user(actor) do
      {:ok, _user} ->
        {:ok, %{result: EmailConnectorSettings.save(params, Map.get(context, :opts, []))}}

      {:error, _} = error ->
        error
    end
  end

  def run(_, _), do: {:error, :unauthorized}
end
