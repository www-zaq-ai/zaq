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
      status: [type: :atom, required: true]
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

  defp handle_response({:ok, status}) when status in [:dispatched, :skipped] do
    {:ok, %{notified: true, status: status}}
  end

  defp handle_response({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp handle_response({:error, reason}), do: {:error, inspect(reason)}
  defp handle_response(other), do: {:error, "notify_person_failed:#{inspect(other)}"}
end
