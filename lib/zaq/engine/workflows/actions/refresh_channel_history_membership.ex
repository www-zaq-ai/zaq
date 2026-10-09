defmodule Zaq.Engine.Workflows.Actions.RefreshChannelHistoryMembership do
  @moduledoc """
  Validated, administrator-only operation to refresh a supported room's provider
  grants. This is a workflow-compatible Action, not an agent tool. The operation
  rechecks the current BO user rather than trusting a workflow parameter.
  """

  @schema Zoi.object(%{
            transcript_id: Zoi.string() |> Zoi.optional(),
            person_id: Zoi.integer() |> Zoi.optional(),
            channel_config_id: Zoi.integer() |> Zoi.optional()
          })
  @output_schema Zoi.object(%{
                   members: Zoi.integer(),
                   rooms: Zoi.integer() |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "refresh_channel_history_membership",
    description: "Refresh verified room membership through the channel's supported capability",
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Accounts.BOActor
  alias Zaq.Engine.ChannelHistoryMembership

  @impl Jido.Action
  def run(params, context) when is_map(params) and is_map(context) do
    case BOActor.current_user(Map.get(context, :actor), allow_password_change: true) do
      {:ok, %{role: %{name: "super_admin"}}} -> refresh(params)
      _ -> {:error, :unauthorized}
    end
  end

  def run(_, _), do: {:error, :unauthorized}

  defp refresh(%{transcript_id: id} = params) when is_binary(id) do
    if is_nil(params[:person_id]) and is_nil(params[:channel_config_id]),
      do: ChannelHistoryMembership.refresh(id),
      else: {:error, :invalid_scope}
  end

  defp refresh(%{person_id: person_id, channel_config_id: config_id} = params)
       when is_integer(person_id) and person_id > 0 and is_integer(config_id) and config_id > 0 do
    if is_nil(params[:transcript_id]),
      do: ChannelHistoryMembership.refresh_person(person_id, config_id),
      else: {:error, :invalid_scope}
  end

  defp refresh(_), do: {:error, :invalid_scope}
end
