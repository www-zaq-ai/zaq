defmodule Zaq.Agent.Tools.People.EnsurePerson do
  @moduledoc """
  Find or create a Person entry from a communication channel identifier.

  Works for any platform supported by `PersonChannel`: email, mattermost,
  slack, microsoft_teams, whatsapp, telegram, discord, etc.

  Matching priority (delegated to `People.find_or_create_from_channel/2`):
    1. email field
    2. phone field
    3. platform + channel_id pair

  On match: back-fills canonical fields (full_name, email, phone) if missing.
  On miss: creates a partial Person entry with `incomplete: true` and links
  the channel.

  Returns `person_id` and passes all input data through as a string-keyed
  `row` map so downstream workflow steps receive the original payload.

  ## Schema

  - `platform`     — required. Channel platform string: `"email"`, `"mattermost"`, etc.
  - `channel_id`   — optional. Primary identifier on the platform (email address,
                     username, user_id). Defaults to the `email` field when
                     `platform` is `"email"`.
  - `display_name` — optional. Person display name for new entries.
  - `email`        — optional. Email address; also used as `channel_id` for
                     `"email"` platform.
  - `phone`        — optional. Phone number for matching.

  ## Example

      EnsurePerson.run(%{platform: "email", email: "jad@zaq.ai", display_name: "Jad"}, %{})
      # => {:ok, %{person_id: 42, row: %{"email" => "jad@zaq.ai", "display_name" => "Jad"}}}
  """

  use Jido.Action,
    name: "ensure_person",
    description: "Find or create a Person from a communication channel identifier.",
    schema: [
      platform: [
        type: :string,
        required: true,
        doc: "Channel platform: email, mattermost, slack, etc."
      ],
      channel_id: [
        type: :string,
        required: false,
        doc: "Primary channel identifier. Defaults to email when platform is 'email'."
      ],
      display_name: [type: :string, required: false, doc: "Person display name for new entries."],
      email: [
        type: :string,
        required: false,
        doc: "Email address; also used as channel_id for 'email' platform."
      ],
      phone: [type: :string, required: false, doc: "Phone number for matching."]
    ],
    output_schema: [
      person_id: [type: :integer, required: false, doc: "ID of the found or created Person."],
      row: [
        type: :map,
        required: true,
        doc: "Input data passed through as string-keyed map for downstream steps."
      ]
    ]

  use Zaq.Engine.Workflows.Action

  require Logger

  alias Zaq.Accounts.People

  @impl Jido.Action
  def run(%{platform: platform} = params, _ctx) do
    email = params[:email] || Map.get(params, "email")

    display_name =
      params[:display_name] || Map.get(params, "display_name") || Map.get(params, "name")

    channel_id = params[:channel_id] || (platform == "email" && email)

    attrs = %{
      "channel_id" => channel_id,
      "display_name" => display_name,
      "email" => email,
      "phone" => params[:phone] || Map.get(params, "phone")
    }

    row = build_row(params)

    case People.find_or_create_from_channel(platform, attrs) do
      {:ok, person} ->
        Logger.info("[EnsurePerson] resolved person_id=#{person.id} platform=#{platform}")
        {:ok, %{person_id: person.id, row: row}}

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
end
