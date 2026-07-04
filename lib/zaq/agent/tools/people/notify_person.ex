defmodule Zaq.Agent.Tools.People.NotifyPerson do
  @moduledoc """
  Requests a person notification through the Engine notification center.

  Channel selection, fallback, provider mapping, logging, and dispatch live in
  `Zaq.Engine.Notifications`; this workflow action only supplies the person and
  message payload.
  """

  use Zaq.Engine.Workflows.Action,
    name: "notify_person",
    description: "Notify a person through the notification center.",
    schema: [
      person: [
        type: :map,
        required: true,
        doc: "Person payload to notify, usually returned by EnsurePerson."
      ],
      subject: [type: :string, required: true, doc: "Notification subject / title."],
      message: [type: :string, required: true, doc: "Notification body text."]
    ],
    output_schema: [
      notified: [type: :boolean, required: true],
      status: [type: :atom, required: true],
      channel: [type: :string, required: false, doc: "Final channel platform used for delivery."],
      channel_identifier: [
        type: :string,
        required: false,
        doc: "Final channel identifier used for delivery."
      ],
      notification_log_id: [type: :integer, required: false, doc: "Notification audit log id."]
    ]

  alias Zaq.Accounts.Person
  alias Zaq.Event
  alias Zaq.NodeRouter

  @spec run(%{person: Person.t() | map(), subject: String.t(), message: String.t()}, map()) ::
          {:ok, %{notified: boolean(), status: atom()}} | {:error, String.t()}
  @impl Jido.Action
  def run(%{person: person, subject: subject, message: message}, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    case person_id(person) do
      id when is_integer(id) ->
        %{person_id: id, subject: subject, message: message}
        |> Event.new(:engine, opts: [action: :notify_person])
        |> node_router.dispatch()
        |> Map.get(:response)
        |> handle_response()

      _ ->
        {:error, "missing_person_id"}
    end
  end

  defp person_id(%Person{id: id}), do: id
  defp person_id(%{id: id}), do: id
  defp person_id(%{"id" => id}), do: id
  defp person_id(_), do: nil

  defp handle_response({:ok, %{status: status} = result}) when status in [:sent, :skipped] do
    {:ok,
     %{
       notified: status == :sent,
       status: status,
       channel: Map.get(result, :channel),
       channel_identifier: Map.get(result, :channel_identifier),
       notification_log_id: Map.get(result, :notification_log_id)
     }}
  end

  defp handle_response({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp handle_response({:error, reason}), do: {:error, inspect(reason)}
  defp handle_response(other), do: {:error, "notify_person_failed:#{inspect(other)}"}
end
