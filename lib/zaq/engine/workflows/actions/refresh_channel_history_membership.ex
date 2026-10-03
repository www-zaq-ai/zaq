defmodule Zaq.Engine.Workflows.Actions.RefreshChannelHistoryMembership do
  @moduledoc """
  Validated, administrator-only operation to refresh a supported room's provider
  grants. This is a workflow-compatible Action, not an agent tool. The operation
  rechecks the current BO user rather than trusting a workflow parameter.
  """

  use Zaq.Engine.Workflows.Action,
    name: "refresh_channel_history_membership",
    description: "Refresh verified room membership through the channel's supported capability",
    schema: [
      transcript_id: [type: :string],
      person_id: [type: :integer],
      channel_config_id: [type: :integer]
    ],
    output_schema: [members: [type: :integer, required: true], rooms: [type: :integer]]

  alias Zaq.Accounts
  alias Zaq.Engine.ChannelHistoryMembership

  @impl Jido.Action
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, user_id} <- actor_user_id(Map.get(context, :actor)),
         %{role: %{name: "super_admin"}} <- Accounts.get_user(user_id) do
      refresh(params)
    else
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

  defp actor_user_id(%{user_id: id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(%{"user_id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(_), do: {:error, :unauthorized}
end
