defmodule Zaq.Agent.Tools.People.UpdatePerson do
  @moduledoc """
  Updates a Person resource, including person fields, communication channels,
  and an optional merge with another person.

  Channel entries with an `id` update that existing channel. Entries without an
  `id` add a new channel to the person.

  Merge precedence is explicit: `merge_precedence: "person"` keeps `person_id`
  as the survivor, while `"other"` keeps `merge_with_person_id` as the survivor.
  The survivor's fields win; missing survivor fields are backfilled from the
  other person. Duplicate channels keep the survivor's channel.
  """

  @merge_precedence_values ["person", "other"]
  @status_values ["active", "inactive"]

  @person_attrs_schema Zoi.object(%{
                         full_name:
                           Zoi.string(description: "Person's display/full name.")
                           |> Zoi.optional(),
                         email:
                           Zoi.string(description: "Canonical email address.")
                           |> Zoi.optional(),
                         phone:
                           Zoi.string(description: "Canonical phone number.")
                           |> Zoi.optional(),
                         role:
                           Zoi.string(description: "Role or title for the person.")
                           |> Zoi.optional(),
                         status:
                           Zoi.enum(@status_values, description: "Person status.")
                           |> Zoi.optional(),
                         metadata:
                           Zoi.map(description: "Additional person metadata.")
                           |> Zoi.optional(),
                         team_ids:
                           Zoi.list(Zoi.integer(), description: "Assigned team ids.")
                           |> Zoi.optional()
                       })

  @channel_schema Zoi.object(%{
                    id:
                      Zoi.integer(
                        description: "Existing channel id. Include this to edit a channel."
                      )
                      |> Zoi.optional(),
                    platform:
                      Zoi.string(
                        description:
                          "Person channel platform. Must be backed by an enabled communication channel config, e.g. email, mattermost, telegram, discord, slack, microsoft_teams. Required when adding a channel."
                      )
                      |> Zoi.optional(),
                    channel_identifier:
                      Zoi.string(
                        description:
                          "Primary channel identifier on the platform, such as email address, username, or user id. Required when adding a channel."
                      )
                      |> Zoi.optional(),
                    username:
                      Zoi.string(description: "Optional platform username.")
                      |> Zoi.optional(),
                    display_name:
                      Zoi.string(description: "Optional platform display name.")
                      |> Zoi.optional(),
                    phone:
                      Zoi.string(description: "Optional platform phone number.")
                      |> Zoi.optional(),
                    dm_channel_id:
                      Zoi.string(description: "Optional direct-message channel id.")
                      |> Zoi.optional(),
                    weight:
                      Zoi.integer(description: "Optional preference weight; lower is preferred.")
                      |> Zoi.optional(),
                    metadata:
                      Zoi.map(description: "Additional channel metadata.")
                      |> Zoi.optional()
                  })
                  |> Zoi.refine({__MODULE__, :validate_channel, []})

  use Zaq.Engine.Workflows.Action,
    name: "update_person",
    description:
      "Update person fields and add or edit communication channels. Optionally merge with another person using explicit survivor precedence.",
    schema:
      Zoi.object(%{
        person_id: Zoi.integer(description: "Person id to update."),
        attrs:
          @person_attrs_schema
          |> Zoi.optional(),
        channels:
          Zoi.list(@channel_schema,
            description: "Optional channel add/edit commands."
          )
          |> Zoi.optional(),
        merge_with_person_id:
          Zoi.integer(description: "Optional person id to merge with.")
          |> Zoi.optional(),
        merge_precedence:
          Zoi.enum(@merge_precedence_values,
            description:
              "Merge survivor: person keeps person_id, other keeps merge_with_person_id."
          )
          |> Zoi.optional()
      }),
    output_schema:
      Zoi.object(%{
        person: Zoi.map(description: "Updated or merged person payload."),
        merged: Zoi.boolean(description: "Whether a merge was performed."),
        merge_precedence:
          Zoi.string(description: "Applied merge precedence, or null when no merge ran.")
          |> Zoi.nullable()
      })

  alias Jido.Action.Tool
  alias Zaq.Channels.ChannelConfig
  alias Zaq.MapUtils

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @doc false
  def validate_channel(channel, _opts \\ [])

  def validate_channel(channel, _opts) when is_map(channel) do
    case validate_add_channel_fields(channel) do
      :ok -> validate_channel_platform(channel)
      error -> error
    end
  end

  def validate_channel(_channel, _opts), do: {:error, "channel must be an object"}

  @impl Jido.Action
  def run(params, context) when is_map(params) do
    person_id = MapUtils.fetch(params, :person_id)
    merge_with_person_id = MapUtils.fetch(params, :merge_with_person_id)
    merge_precedence = MapUtils.fetch(params, :merge_precedence) || "person"

    params
    |> build_request(person_id, merge_with_person_id, merge_precedence)
    |> dispatch_request(context)
    |> handle_response(merge_with_person_id, merge_precedence)
  end

  def run(_params, _context), do: {:error, "params must be a map"}

  defp build_request(params, person_id, merge_with_person_id, merge_precedence) do
    %{
      op: :update_resource,
      params: %{
        id: person_id,
        attrs: MapUtils.fetch(params, :attrs) || %{},
        channels: MapUtils.fetch(params, :channels) || [],
        merge: %{
          merge_with_person_id: merge_with_person_id,
          merge_precedence: merge_precedence
        }
      }
    }
  end

  defp dispatch_request(request, context) do
    event = Zaq.Event.new(request, :engine, opts: [action: :people_command])
    node_router = MapUtils.fetch(context || %{}, :node_router) || Zaq.NodeRouter

    node_router.dispatch(event) |> Map.get(:response)
  end

  defp handle_response({:ok, person}, merge_with_person_id, merge_precedence) do
    {:ok,
     %{
       person: person_payload(person),
       merged: not is_nil(merge_with_person_id),
       merge_precedence: if(is_nil(merge_with_person_id), do: nil, else: merge_precedence)
     }}
  end

  defp handle_response({:error, reason}, _merge_with_person_id, _merge_precedence),
    do: {:error, format_error(reason)}

  defp handle_response(other, _merge_with_person_id, _merge_precedence),
    do: {:error, format_error(other)}

  defp person_payload(person) do
    %{
      id: person.id,
      full_name: person.full_name,
      email: person.email,
      phone: person.phone,
      role: person.role,
      status: person.status,
      incomplete: person.incomplete,
      channels: Enum.map(Map.get(person, :channels, []), &channel_payload/1)
    }
  end

  defp channel_payload(channel) do
    %{
      id: channel.id,
      platform: channel.platform,
      channel_identifier: channel.channel_identifier,
      username: channel.username,
      display_name: channel.display_name,
      phone: channel.phone,
      dm_channel_id: channel.dm_channel_id,
      weight: channel.weight,
      metadata: channel.metadata || %{}
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp validate_add_channel_fields(channel) do
    if present?(MapUtils.fetch(channel, :id)) do
      :ok
    else
      cond do
        not present?(MapUtils.fetch(channel, :platform)) ->
          {:error, "platform is required when adding a channel"}

        not present?(MapUtils.fetch(channel, :channel_identifier)) ->
          {:error, "channel_identifier is required when adding a channel"}

        true ->
          :ok
      end
    end
  end

  defp validate_channel_platform(channel) do
    platform = MapUtils.fetch(channel, :platform)

    if present?(platform) and not incoming_platform?(platform) do
      {:error, "platform must be backed by an enabled communication channel config"}
    else
      :ok
    end
  end

  defp incoming_platform?(platform) do
    platform
    |> ChannelConfig.list_incoming_routing_configs_for_platform()
    |> Enum.any?()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
