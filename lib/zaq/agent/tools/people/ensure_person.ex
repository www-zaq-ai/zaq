defmodule Zaq.Agent.Tools.People.EnsurePerson do
  @moduledoc """
  Find or create a Person entry from a communication channel identifier.

  Works for any platform supported by `PersonChannel`: email, mattermost,
  slack, microsoft_teams, whatsapp, telegram, discord, etc.

  Matching priority (delegated to `People.find_or_create_from_channel/2`):
    1. native identity within the Channels-defined authority
    2. existing connector link, then canonical email (legacy unscoped inputs also match phone)
    3. create a partial Person and link the identity

  Conflicting established owners fail atomically. Bot configuration identifies a
  delivery link, not a distinct Person; supply it for server/tenant-scoped IDs.

  On match: back-fills canonical fields (full_name, email, phone) if missing.
  On miss: creates a partial Person entry with `incomplete: true` and links
  the channel.

  Returns a JSON-safe person payload and passes all input data through as a
  string-keyed `row` map so downstream workflow steps receive the original
  payload. Downstream steps should read the id from `person.id` when needed.

  ## Schema

  - `platform`     — required. Channel platform string: `"email"`, `"mattermost"`, etc.
  - `channel_id`   — optional. Primary identifier on the platform (email address,
                     username, user_id). Defaults to the `email` field when
                     `platform` is `"email"`.
  - `display_name` — optional. Person display name for new entries.
  - `channel_config_id` — optional. Connector supplying the native identity authority.
  - `email`        — optional. Email address; also used as `channel_id` for
                     `"email"` platform.
  - `phone`        — optional. Phone number for matching.

  ## Example

      EnsurePerson.run(%{platform: "email", email: "jad@zaq.ai", display_name: "Jad"}, %{})
      # => {:ok, %{person: %{id: 1, email: "jad@zaq.ai", full_name: "Jad"}, row: %{"email" => "jad@zaq.ai", "display_name" => "Jad"}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "ensure_person",
    description: "Find or create a Person from a communication channel identifier.",
    schema:
      Zoi.object(
        %{
          platform: Zoi.string(description: "Channel platform: email, mattermost, slack, etc."),
          channel_config_id:
            Zoi.integer(description: "Connector supplying the native identity authority.")
            |> Zoi.optional(),
          channel_id:
            Zoi.string(
              description:
                "Primary channel identifier. Defaults to email when platform is 'email'."
            )
            |> Zoi.optional(),
          display_name:
            Zoi.string(description: "Person display name for new entries.")
            |> Zoi.optional(),
          email:
            Zoi.string(
              description: "Email address; also used as channel_id for 'email' platform."
            )
            |> Zoi.optional(),
          phone: Zoi.string(description: "Phone number for matching.") |> Zoi.optional()
        },
        unrecognized_keys: :preserve
      ),
    output_schema:
      Zoi.object(%{
        person: Zoi.map(description: "Found or created person payload."),
        row:
          Zoi.map(
            description: "Input data passed through as string-keyed map for downstream steps."
          )
      })

  require Logger

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person

  @spec run(map(), map()) ::
          {:ok, %{person: map(), row: map()}} | {:error, String.t()}
  @impl Jido.Action
  def run(%{platform: platform} = params, ctx) do
    email = params[:email] || Map.get(params, "email")

    display_name =
      params[:display_name] || Map.get(params, "display_name") || Map.get(params, "name")

    channel_id = params[:channel_id] || (platform == "email" && email)

    attrs = %{
      "channel_id" => channel_id,
      "channel_config_id" => connector_id(params),
      "display_name" => display_name,
      "email" => email,
      "phone" => params[:phone] || Map.get(params, "phone")
    }

    row = build_row(params)

    case people_module(ctx).find_or_create_from_channel(platform, attrs) do
      {:ok, person} ->
        Logger.info("[EnsurePerson] resolved person_id=#{person.id} platform=#{platform}")
        {:ok, %{person: person_payload(person), row: row}}

      {:error, reason} ->
        Logger.warning("[EnsurePerson] failed platform=#{platform} reason=#{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # Converts all input params to a string-keyed row map, dropping internal
  # platform fields that have no meaning for downstream steps.
  defp build_row(params) do
    params
    |> Map.drop([:platform])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp people_module(%{people_module: module}), do: module
  defp people_module(%{"people_module" => module}), do: module
  defp people_module(_ctx), do: People

  defp connector_id(params),
    do: params[:channel_config_id] || Map.get(params, "channel_config_id")

  defp person_payload(%Person{} = person) do
    %{
      id: person.id,
      full_name: person.full_name,
      email: person.email,
      phone: person.phone,
      role: person.role,
      status: person.status,
      incomplete: person.incomplete
    }
  end
end
