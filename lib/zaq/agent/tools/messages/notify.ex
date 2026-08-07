defmodule Zaq.Agent.Tools.Messages.Notify do
  @moduledoc """
  Sends a message to one channel destination through the notification center.

  The action only names *where* to deliver (`channel` + `destination`) and
  *what* to deliver (`payload`). Provider resolution, availability filtering,
  logging, threading, and dispatch stay in `Zaq.Engine.Notifications`.

  `payload` is either a plain string used as the message body, or an object
  carrying `subject`, `body`, `html_body`, and `metadata` for channels that
  need a title alongside the body, such as email. When no subject is given, one
  is derived from the first line of the body.
  """

  @subject_max_length 120
  @fallback_subject "Notification"

  @payload_object_schema Zoi.object(%{
                           subject:
                             Zoi.string(
                               description:
                                 "Message title, used by channels that carry one such as email."
                             )
                             |> Zoi.optional(),
                           body: Zoi.string(description: "Plain-text message body."),
                           html_body:
                             Zoi.string(description: "Optional HTML version of the body.")
                             |> Zoi.optional(),
                           metadata:
                             Zoi.map(description: "Additional message metadata.")
                             |> Zoi.optional()
                         })

  use Zaq.Engine.Workflows.Action,
    name: "notify",
    description:
      "Send a message to one destination on one communication channel through the notification center.",
    schema:
      Zoi.object(%{
        channel:
          Zoi.string(
            description:
              "Channel to deliver on, e.g. email, mattermost, telegram. Must be backed by an enabled communication channel config."
          ),
        destination:
          Zoi.string(
            description:
              "Destination on that channel: email address, username, user id, or chat/channel id."
          ),
        payload:
          Zoi.union([Zoi.string(), @payload_object_schema],
            description:
              "Message body as a plain string, or an object with subject, body, html_body, and metadata."
          )
      }),
    output_schema:
      Zoi.object(%{
        notified: Zoi.boolean(description: "Whether the message was delivered."),
        status: Zoi.enum(["sent", "skipped", "failed"], description: "Delivery outcome."),
        channel: Zoi.string(description: "Channel the message was delivered on."),
        destination: Zoi.string(description: "Destination the message was delivered to."),
        subject: Zoi.string(description: "Subject the message was sent with."),
        body: Zoi.string(description: "Body the message was sent with."),
        notification_log_id:
          Zoi.integer(description: "Notification audit log id.")
          |> Zoi.nullable(),
        message_id:
          Zoi.string(
            description:
              "The sent message's own id on the provider, when the channel returns one."
          )
          |> Zoi.nullable(),
        thread_id:
          Zoi.string(
            description: "Thread pointer the message belongs to, when the channel threads."
          )
          |> Zoi.nullable(),
        thread_metadata:
          Zoi.map(
            description: "Opaque channel-specific threading residue, never interpreted here."
          )
      })

  alias Jido.Action.Tool
  alias Zaq.Event
  alias Zaq.MapUtils
  alias Zaq.NodeRouter

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
  @impl Jido.Action
  def run(params, context) when is_map(params) do
    channel = MapUtils.fetch(params, :channel)
    destination = MapUtils.fetch(params, :destination)

    with :ok <- validate_recipient(channel, destination),
         {:ok, message} <- build_message(MapUtils.fetch(params, :payload)) do
      channel
      |> build_request(destination, message)
      |> dispatch_request(context)
      |> handle_response(channel, destination, message)
    end
  end

  def run(_params, _context), do: {:error, "params must be a map"}

  defp validate_recipient(channel, destination) do
    cond do
      not present?(channel) -> {:error, "channel is required"}
      not present?(destination) -> {:error, "destination is required"}
      true -> :ok
    end
  end

  defp build_message(payload) when is_binary(payload) do
    build_message(%{body: payload})
  end

  defp build_message(payload) when is_map(payload) do
    body = MapUtils.fetch(payload, :body)

    if present?(body) do
      {:ok,
       %{
         subject: subject(MapUtils.fetch(payload, :subject), body),
         body: body,
         html_body: MapUtils.fetch(payload, :html_body),
         metadata: MapUtils.fetch(payload, :metadata) || %{}
       }}
    else
      {:error, "payload body is required"}
    end
  end

  defp build_message(_payload), do: {:error, "payload must be a string or an object"}

  # Channels without a subject line still need one for the notification log, so
  # an absent subject falls back to the body's first line.
  defp subject(subject, _body) when is_binary(subject) do
    case String.trim(subject) do
      "" -> @fallback_subject
      trimmed -> trimmed
    end
  end

  defp subject(_subject, body) do
    body
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @subject_max_length)
    |> case do
      "" -> @fallback_subject
      derived -> derived
    end
  end

  defp build_request(channel, destination, message) do
    %{
      recipient_channels: [%{platform: channel, identifier: destination}],
      subject: message.subject,
      body: message.body,
      html_body: message.html_body,
      metadata: message.metadata
    }
  end

  defp dispatch_request(request, context) do
    node_router = MapUtils.fetch(context || %{}, :node_router) || NodeRouter

    request
    |> Event.new(:engine, opts: [action: :notify])
    |> node_router.dispatch()
    |> Map.get(:response)
  end

  defp handle_response({:ok, %{status: status} = result}, channel, destination, message)
       when status in [:sent, :skipped] do
    {:ok,
     %{
       notified: status == :sent,
       status: to_string(status),
       channel: Map.get(result, :channel) || channel,
       destination: Map.get(result, :channel_identifier) || destination,
       subject: message.subject,
       body: message.body,
       notification_log_id: Map.get(result, :notification_log_id),
       message_id: Map.get(result, :message_id),
       thread_id: Map.get(result, :thread_id),
       thread_metadata: Map.get(result, :thread_metadata, %{})
     }}
  end

  defp handle_response({:error, reason}, _channel, _destination, _message),
    do: {:error, format_error(reason)}

  defp handle_response(other, _channel, _destination, _message),
    do: {:error, "notify_failed:#{inspect(other)}"}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{reason: reason}), do: "notify_failed:#{inspect(reason)}"
  defp format_error(reason), do: inspect(reason)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
