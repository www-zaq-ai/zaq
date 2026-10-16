defmodule Zaq.Engine.Conversations.MessageAuthor do
  @moduledoc """
  Conversations-owned author attribution for already-scoped message batches.

  Only recorded author Person references select directory names. People owns the
  alias-aware batch query; this module owns message presentation and fallbacks.
  Names are resolved at preparation/load time, not refreshed in agent state.
  Attribution never changes content, author evidence or access decisions.
  """

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Incoming

  @doc """
  Presents a non-persisted Engine-resolved input without directory I/O. Its Person
  payload is directory data already supplied by ingress, not a channel display
  name. Only its trusted source timestamp can supply message time.
  Persisted inputs must instead use their authorized stored-message projection.
  """
  def from_input(%Incoming{} = incoming) do
    person = incoming.person || %{}
    id = Incoming.person_id(incoming)
    message = %{history_context: %{"author_person_id" => id}}

    %{
      role: "user",
      content: incoming.content,
      attachments: incoming.attachments,
      author: author(message, %{id => person}),
      timestamp:
        Message.presentation_timestamp(%{
          provider_sent_at: incoming.routing_context.provider_sent_at
        })
    }
  end

  @doc "Attaches author metadata using at most one directory query for the batch."
  @spec project([map()]) :: [map()]
  def project(messages) when is_list(messages) do
    people =
      messages
      |> Enum.filter(&human_message?/1)
      |> Enum.map(&author_person_id/1)
      |> People.get_people_by_ids()

    Enum.map(messages, fn message ->
      message
      |> Map.put(:author, author(message, people))
      |> Map.put(:timestamp, Message.presentation_timestamp(message))
    end)
  end

  defp author(%{role: role} = message, _people) when role in [:assistant, "assistant"] do
    metadata = Map.get(message, :metadata) || %{}

    name =
      case metadata["agent"] || metadata[:agent] do
        agent when is_map(agent) -> agent["name"] || agent[:name]
        agent when is_binary(agent) -> agent
        _ -> nil
      end

    %{kind: :assistant, person_id: nil, name: display_name(name, "Assistant")}
  end

  defp author(%{role: role}, _people) when role in [:system, "system"],
    do: %{kind: :system, person_id: nil, name: "System"}

  defp author(%{role: role} = message, _people) when role in [:tool, "tool"],
    do: %{kind: :tool, person_id: nil, name: display_name(Map.get(message, :name), "Tool")}

  defp author(message, people) do
    id = author_person_id(message)
    person = Map.get(people, id)
    name = if person, do: Map.get(person, :full_name)

    %{
      kind: if(is_integer(id), do: :person, else: :unknown),
      person_id: id,
      name: display_name(name, "Unknown author")
    }
  end

  defp human_message?(%{role: role}), do: role in [:user, "user", :external, "external"]
  defp human_message?(_message), do: false

  defp author_person_id(message) do
    case (Map.get(message, :history_context) || %{})["author_person_id"] do
      id when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 -> id
      _ -> nil
    end
  end

  defp display_name(name, fallback) when is_binary(name) do
    if String.trim(name) == "", do: fallback, else: name
  end

  defp display_name(_name, fallback), do: fallback
end
