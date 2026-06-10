defmodule Zaq.Agent.Tools.People.NotifyPerson do
  @moduledoc """
  Sends a notification to a person via a specified medium (channel platform).

  Looks up the person's channel identifier for the requested `medium`, builds
  a `%Notification{}`, and dispatches it through `Zaq.Engine.Notifications.notify/1`
  — the canonical notification exit point.

  ## Schema

  - `person_id` — required. ID of the person to notify.
  - `medium`    — required. Platform to use: `"email"`, `"mattermost"`, `"slack"`, etc.
                  Must match a `PersonChannel.platform` value for that person.
  - `subject`   — required. Notification subject / title.
  - `message`   — required. Notification body text.

  ### Optional sheet-tracking fields

  When a subsequent workflow step needs to update a spreadsheet cell (e.g. to
  increment an email-state counter), pass these and the computed `range` /
  `values` will be included in the output for direct use by
  `UpdateSheetValues`:

  - `row_index`          — 1-based sheet row number.
  - `email_state`        — current counter value; output will carry `email_state + 1`.
  - `email_state_column` — column letter (default `"I"`).

  ## Output

  - `notified`           — `true` when dispatched or skipped (no error).
  - `channel_identifier` — the identifier used (e.g. email address).
  - `status`             — `:dispatched` | `:skipped`.
  - `range`              — A1 range string, e.g. `"Sheet1!I5"` (only when sheet params given).
  - `values`             — 2-D matrix ready for `UpdateSheetValues`, e.g. `[[3]]` (only when sheet params given).

  ## Example

      NotifyPerson.run(
        %{person_id: 42, medium: "email", subject: "Hello", message: "How are you?"},
        %{}
      )
      # => {:ok, %{notified: true, channel_identifier: "jad@example.com", status: :dispatched}}
  """

  use Jido.Action,
    name: "notify_person",
    description: "Notify a person via a configured channel medium (email, mattermost, slack…).",
    schema: [
      person_id: [type: :any, required: true, doc: "Person ID (integer or string)."],
      medium: [
        type: :string,
        required: true,
        doc: "Channel platform: email, mattermost, slack, etc."
      ],
      subject: [type: :string, required: true, doc: "Notification subject / title."],
      message: [type: :string, required: true, doc: "Notification body text."],
      row_index: [
        type: :integer,
        required: false,
        doc: "1-based sheet row number (enables range/values output)."
      ],
      email_state: [
        type: :integer,
        required: false,
        default: 0,
        doc: "Current sheet counter value. Output will carry email_state + 1."
      ],
      email_state_column: [
        type: :string,
        required: false,
        default: "I",
        doc: "Column letter for the sheet counter cell."
      ]
    ],
    output_schema: [
      notified: [type: :boolean, required: true],
      channel_identifier: [type: :string, required: false],
      status: [type: :atom, required: true],
      range: [type: :string, required: false],
      values: [type: {:list, {:list, :any}}, required: false]
    ]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Accounts.People
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.Notification

  # Maps PersonChannel.platform → Notifications channel platform string.
  # PersonChannel stores short platform names; Notifications uses provider keys.
  @platform_map %{
    "email" => "email:smtp"
  }

  @impl Jido.Action
  def run(
        %{person_id: person_id, medium: medium, subject: subject, message: message} = params,
        ctx
      ) do
    notifications = Map.get(ctx, :notifications, Notifications)

    with {:ok, person} <- fetch_person(person_id),
         {:ok, identifier} <- find_channel_identifier(person, medium) do
      notification_platform = Map.get(@platform_map, medium, medium)

      case Notification.build(%{
             recipient_name: person.full_name,
             recipient_ref: {:person, person.id},
             recipient_channels: [%{platform: notification_platform, identifier: identifier}],
             subject: subject,
             body: message
           }) do
        {:ok, notification} ->
          send_notification(notifications, notification, identifier, params)

        {:error, reason} ->
          {:error, "invalid_notification:#{reason}"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp send_notification(notifications, notification, identifier, params) do
    case notifications.notify(notification) do
      {:ok, status} ->
        {:ok,
         %{notified: true, channel_identifier: identifier, status: status}
         |> maybe_put_sheet_fields(params)}

      {:error, reason} ->
        {:error, "notify_failed:#{inspect(reason)}"}
    end
  end

  defp fetch_person(person_id) do
    case People.get_person_with_channels(person_id) do
      nil -> {:error, "person_not_found:#{person_id}"}
      person -> {:ok, person}
    end
  end

  defp find_channel_identifier(person, medium) do
    case Enum.find(person.channels, fn ch -> ch.platform == medium end) do
      nil -> {:error, "no_channel_for_medium:#{medium}"}
      channel -> {:ok, channel.channel_identifier}
    end
  end

  # Adds range + values to the output when sheet-tracking params are present.
  # row_index and email_state may arrive as strings from Google Sheet cascades.
  defp maybe_put_sheet_fields(output, %{row_index: raw_row} = params) do
    case to_integer(raw_row, nil) do
      nil ->
        output

      row_index ->
        email_state = params |> Map.get(:email_state, 0) |> to_integer(0)
        column = Map.get(params, :email_state_column, "I")

        output
        |> Map.put(:range, "Sheet1!#{column}#{row_index}")
        |> Map.put(:values, [[email_state + 1]])
    end
  end

  defp maybe_put_sheet_fields(output, _params), do: output

  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_integer(_value, default), do: default
end
