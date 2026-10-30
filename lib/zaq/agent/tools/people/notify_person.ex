defmodule Zaq.Agent.Tools.People.NotifyPerson do
  @moduledoc """
  Requests a person notification through the Engine notification center.

  Channel selection, fallback, provider mapping, logging, and dispatch live in
  `Zaq.Engine.Notifications`; this workflow action only supplies the person and
  message payload.

  Trusted context `event_opts: [confidential: true]` suppresses notification
  observation and returns safe structured failures to Jido after logging only
  diagnostic classes and source locations. Ordinary callers retain binary errors.
  """

  @person_schema Zoi.object(
                   %{
                     "id" => Zoi.integer(description: "Person id to notify."),
                     "full_name" =>
                       Zoi.any(description: "Person display name.") |> Zoi.optional(),
                     "email" => Zoi.any(description: "Person email address.") |> Zoi.optional(),
                     "phone" => Zoi.any(description: "Person phone number.") |> Zoi.optional(),
                     "role" => Zoi.any(description: "Person role or title.") |> Zoi.optional(),
                     "status" => Zoi.any(description: "Person status.") |> Zoi.optional(),
                     "incomplete" =>
                       Zoi.any(description: "Whether the person profile is incomplete.")
                       |> Zoi.optional()
                   },
                   coerce: true,
                   unrecognized_keys: :preserve,
                   description: "Person payload to notify, usually returned by EnsurePerson."
                 )

  use Zaq.Engine.Workflows.Action,
    name: "notify_person",
    description: "Notify a person through the notification center.",
    schema:
      Zoi.object(
        %{
          person: @person_schema,
          subject: Zoi.string(description: "Notification subject / title."),
          message: Zoi.string(description: "Notification body text.")
        },
        coerce: true,
        unrecognized_keys: :preserve
      ),
    output_schema:
      Zoi.object(%{
        notified: Zoi.boolean(),
        status: Zoi.atom(),
        channel:
          Zoi.string(description: "Final channel platform used for delivery.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        channel_identifier:
          Zoi.string(description: "Final channel identifier used for delivery.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        provider:
          Zoi.string(description: "Alias for the final delivery channel.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        channel_id:
          Zoi.string(description: "Alias for the final channel identifier.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        author_id:
          Zoi.string(description: "Alias for the final channel identifier.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        person:
          Zoi.map(description: "Person payload that was notified.")
          |> Zoi.optional(),
        person_id:
          Zoi.integer(description: "Person id that was notified.")
          |> Zoi.optional(),
        subject: Zoi.string(description: "Notification subject.") |> Zoi.optional(),
        message: Zoi.string(description: "Notification body text.") |> Zoi.optional(),
        content:
          Zoi.string(description: "Alias for the notification body text.")
          |> Zoi.optional(),
        notification_log_id:
          Zoi.integer(description: "Notification audit log id.")
          |> Zoi.nullable()
          |> Zoi.optional(),
        # Generic, cross-channel threading pointers — a chat post has both of these
        # too. Deliberately NOT `references`: that chain is email-only and stays
        # inside the opaque `thread_metadata`, which this action never interprets.
        message_id:
          Zoi.string(
            description:
              "The sent message's own id on the provider (email Message-ID, chat post id)."
          )
          |> Zoi.nullable()
          |> Zoi.optional(),
        thread_id:
          Zoi.string(
            description:
              "Thread pointer the message belongs to (email thread root, chat root_id)."
          )
          |> Zoi.nullable()
          |> Zoi.optional(),
        thread_metadata:
          Zoi.map(
            description:
              "Opaque channel-specific threading residue, forwarded verbatim to persistence."
          )
          |> Zoi.optional()
      })

  alias Jido.Action.Error
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Events
  alias Zaq.NodeRouter
  require Logger

  @spec run(%{person: Person.t() | map(), subject: String.t(), message: String.t()}, map()) ::
          {:ok, %{notified: boolean(), status: atom()}} | {:error, String.t() | Exception.t()}
  @impl Jido.Action
  def run(%{person: person, subject: subject, message: message}, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    case person_id(person) do
      id when is_integer(id) ->
        %{person_id: id, subject: subject, message: message}
        |> Events.build_invoke_event(:notify_person,
          event_opts: [
            confidential: Keyword.get(Map.get(context, :event_opts, []), :confidential) == true
          ]
        )
        |> dispatch_notification(node_router)
        |> handle_response(subject, message, person)

      _ ->
        {:error, "missing_person_id"}
    end
  end

  # Confidential failures must be made safe before Jido's own error logger sees
  # them. Ordinary workflow callers retain their existing error contract.
  defp dispatch_notification(event, node_router) do
    case {node_router.dispatch(event).response, event.opts[:confidential]} do
      {{:ok, %{status: status}} = response, true} when status in [:sent, :skipped] ->
        response

      {{:error, reason}, true} ->
        confidential_failure(reason, event, :delivery, [])

      {response, true} ->
        confidential_failure(response, event, :delivery, [])

      {response, _} ->
        response
    end
  rescue
    error ->
      if event.opts[:confidential] do
        confidential_failure(error, event, :execution, __STACKTRACE__)
      else
        reraise error, __STACKTRACE__
      end
  catch
    kind, reason ->
      if event.opts[:confidential] do
        confidential_failure(kind, event, :execution, [])
      else
        :erlang.raise(kind, reason, __STACKTRACE__)
      end
  end

  defp confidential_failure(reason, event, phase, stacktrace) do
    exception_type = if is_exception(reason), do: reason.__struct__, else: :unknown
    category = if reason in [:exit, :throw], do: reason, else: :failure
    source = source_metadata(stacktrace)

    Logger.warning(
      "[NotifyPerson] confidential notification failed phase=#{phase} " <>
        "exception_type=#{inspect(exception_type)} source=#{inspect(source)}",
      [event_id: event.trace_id, phase: phase, category: category, exception_type: exception_type] ++
        source
    )

    {:confidential_error,
     Error.execution_error(
       "confidential_notification_failed",
       %{phase: phase, exception_type: exception_type, retry: false}
     )}
  end

  defp source_metadata([{module, function, args, _location} | _])
       when is_atom(module) and is_atom(function) do
    arity = if is_list(args), do: length(args), else: args
    [source_module: module, source_function: function, source_arity: arity]
  end

  defp source_metadata(_), do: []

  defp person_id(%Person{id: id}), do: id
  defp person_id(%{id: id}), do: id
  defp person_id(%{"id" => id}), do: id
  defp person_id(_), do: nil

  defp handle_response({:ok, %{status: status} = result}, subject, message, person)
       when status in [:sent, :skipped] do
    channel = Map.get(result, :channel)
    channel_identifier = Map.get(result, :channel_identifier)
    person_payload = person_payload(person)

    {:ok,
     %{
       notified: status == :sent,
       status: status,
       channel: channel,
       channel_identifier: channel_identifier,
       provider: channel,
       channel_id: channel_identifier,
       author_id: channel_identifier,
       person: person_payload,
       person_id: person_payload[:id],
       subject: subject,
       message: message,
       content: message,
       notification_log_id: Map.get(result, :notification_log_id),
       # Only a delivered message can be a parent — Notifications surfaces these on
       # `:sent` alone, so a skipped/failed send stores no phantom anchor (Bug #3).
       message_id: Map.get(result, :message_id),
       thread_id: Map.get(result, :thread_id),
       thread_metadata: Map.get(result, :thread_metadata, %{})
     }}
  end

  defp handle_response({:confidential_error, reason}, _subject, _message, _person),
    do: {:error, reason}

  defp handle_response({:error, reason}, _subject, _message, _person) when is_binary(reason),
    do: {:error, reason}

  defp handle_response({:error, reason}, _subject, _message, _person),
    do: {:error, inspect(reason)}

  defp handle_response(other, _subject, _message, _person),
    do: {:error, "notify_person_failed:#{inspect(other)}"}

  defp person_payload(%Person{} = person) do
    person
    |> Map.from_struct()
    |> Map.take([:id, :full_name, :email, :phone, :role, :status, :incomplete])
  end

  defp person_payload(person) when is_map(person) do
    [:id, :full_name, :email, :phone, :role, :status, :incomplete]
    |> Map.new(fn key -> {key, Map.get(person, key) || Map.get(person, to_string(key))} end)
  end
end
