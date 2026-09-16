defmodule Zaq.Engine.PeopleConversations do
  @moduledoc """
  Authorized self-service conversation boundary. Every operation derives the
  current literal owner from a server-held People bearer. Authentication locks
  remain held in the outer transaction; conversation writes additionally lock
  their parent before reading children. Browser owner and author fields are ignored.
  """
  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.Conversations
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Repo

  @history [:access_profile, :access_message_history]
  @sharing @history ++ [:share_conversations]
  @writes [:rate, :share, :revoke_share]
  @share_ops [:shares, :share, :revoke_share]
  @operations [
    :list,
    :detail,
    :message,
    :rate,
    :shares,
    :share,
    :revoke_share,
    :source,
    :artifact
  ]
  @page_size 25

  @doc "Dispatches only fixed conversation operations using fresh authentication."
  @spec dispatch(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%{token: token, op: op} = request, opts) do
    Repo.transaction(fn ->
      with {:ok, auth} <- PeopleAuth.authenticate(token, opts),
           :ok <- authorize(auth.person, op),
           {:ok, result} <- execute(op, request, auth) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def dispatch(_, _), do: {:error, :invalid_request}

  defp authorize(person, op) do
    cond do
      op not in @operations ->
        {:error, :forbidden}

      !PeoplePermissions.allowed?(person, @history) ->
        {:error, :forbidden}

      op in @share_ops && !PeoplePermissions.allowed?(person, @sharing) ->
        {:error, :share_forbidden}

      true ->
        :ok
    end
  end

  defp execute(:list, request, auth) do
    filters = filters(request, auth.person.id)
    total = Conversations.count_conversations(filters)
    pages = max(1, ceil(total / @page_size))
    page = min(page_number(Map.get(request, :page)), pages)

    conversations =
      Conversations.list_conversations(
        filters ++ [limit: @page_size, offset: (page - 1) * @page_size, preload: []]
      )

    {:ok,
     %{
       conversations: Enum.map(conversations, &conversation_data/1),
       total: total,
       page: page,
       total_pages: pages,
       person: Map.take(auth.person, [:full_name]),
       permissions: auth.permissions
     }}
  end

  defp execute(op, request, auth) do
    case Conversations.get_person_conversation(Map.get(request, :conversation_id), auth.person.id,
           lock: op in @writes
         ) do
      nil -> {:error, :not_found}
      conversation -> conversation_operation(op, request, auth, conversation)
    end
  end

  defp conversation_operation(:detail, _, auth, conversation) do
    can_share = PeoplePermissions.allowed?(auth.person, @sharing)
    messages = Conversations.list_messages(conversation, rating_person_id: auth.person.id)
    shares = if can_share, do: Conversations.list_shares(conversation), else: []

    {:ok,
     %{
       conversation: conversation_data(conversation),
       messages: messages,
       shares: shares,
       can_share: can_share,
       person: Map.take(auth.person, [:full_name]),
       permissions: auth.permissions
     }}
  end

  defp conversation_operation(:message, request, _auth, conversation) do
    case Conversations.get_conversation_message(conversation, Map.get(request, :message_id)) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  defp conversation_operation(:source, request, auth, conversation) do
    with message when not is_nil(message) <-
           Conversations.get_conversation_message(conversation, Map.get(request, :message_id)),
         source when is_binary(source) <- Map.get(request, :source),
         reference when not is_nil(reference) <-
           Enum.find(message.sources || [], &(source_path(&1) === source)) do
      {:ok,
       %{
         kind: :source,
         document_reference: source_path(reference),
         actor: ActorNormalizer.from_person_payload(nil, auth.person)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp conversation_operation(:artifact, request, auth, conversation) do
    with message when not is_nil(message) <-
           Conversations.get_conversation_message(conversation, Map.get(request, :message_id)),
         artifact when not is_nil(artifact) <-
           Conversations.get_message_trace_artifact(message, Map.get(request, :artifact_id)),
         true <- trace_references?(message.trace, artifact.id) do
      {:ok,
       %{
         kind: :record,
         record: Map.take(artifact, [:content, :name, :mime_type]),
         document_reference: artifact.record,
         actor: ActorNormalizer.from_person_payload(nil, auth.person)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp conversation_operation(:rate, request, auth, conversation) do
    with %{role: "assistant"} = message <-
           Conversations.get_conversation_message(conversation, Map.get(request, :message_id),
             lock: true
           ),
         attrs when is_non_struct_map(attrs) <- Map.get(request, :attrs) do
      attrs = %{
        person_id: auth.person.id,
        rating: value(attrs, :rating),
        comment: value(attrs, :comment)
      }

      Conversations.upsert_rating(message, attrs)
    else
      _ -> {:error, :not_found}
    end
  end

  defp conversation_operation(:shares, _, _, conversation),
    do: {:ok, Conversations.list_shares(conversation)}

  defp conversation_operation(:share, request, _, conversation) do
    case Map.get(request, :attrs, %{}) do
      attrs when is_non_struct_map(attrs) ->
        Conversations.share_conversation(conversation, %{
          permission: value(attrs, :permission) || "read",
          expires_at: value(attrs, :expires_at)
        })

      _ ->
        {:error, :invalid_request}
    end
  end

  defp conversation_operation(:revoke_share, request, _, conversation) do
    case Conversations.get_conversation_share(conversation, Map.get(request, :share_id)) do
      nil -> {:error, :not_found}
      share -> Conversations.revoke_share(share)
    end
  end

  defp conversation_data(conversation),
    do: Map.take(conversation, [:id, :title, :channel_type, :status, :inserted_at, :updated_at])

  defp trace_references?(traces, id) when is_list(traces) do
    Enum.any?(traces, fn
      %{"artifacts" => artifacts} when is_list(artifacts) ->
        Enum.any?(artifacts, &(is_map(&1) && &1["id"] == id))

      _ ->
        false
    end)
  end

  defp trace_references?(_, _), do: false
  defp source_path(%{"path" => source}), do: source
  defp source_path(%{"source" => source}), do: source
  defp source_path(%{"attributes" => %{"source" => source}}), do: source
  defp source_path(source) when is_binary(source), do: source
  defp source_path(_), do: nil

  defp filters(request, person_id) do
    Enum.reduce([:status, :channel_type], [person_id: person_id], fn key, filters ->
      case Map.get(request, key) do
        value when is_binary(value) and value not in ["", "all"] -> [{key, value} | filters]
        _ -> filters
      end
    end)
  end

  defp page_number(page) when is_integer(page) and page > 0, do: page

  defp page_number(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp page_number(_), do: 1
  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
