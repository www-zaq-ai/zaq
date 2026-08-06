defmodule Zaq.Engine.Messages.Incoming do
  @moduledoc """
  Canonical inbound message payload struct.

  Every channel adapter (Mattermost, Slack, HTTP, etc.) must map its transport-specific
  payload to this struct before passing a message to any ZAQ component (Pipeline, Bridge,
  Conversations, etc.). Nothing inside ZAQ should depend on adapter-specific envelope types.

  Use `new/1` as the canonical constructor. It normalizes payload shape and injects
  telemetry dimensions into metadata so pipeline callers do not need to build telemetry
  maps manually.

  For cross-node routing, this struct is wrapped by `%Zaq.Event{request: %Incoming{...}}`.

  `attachments` carries the media sent alongside the text as a `Zaq.Contracts.RecordPage`.
  Records on an inbound message arrive **unmaterialized** — `content: nil` plus a
  `materializing_event` — so a photo does not drag its bytes through every hop that only
  needed to know a photo exists.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Identity.ActorNormalizer

  @enforce_keys [:content, :channel_id, :provider]

  @empty_attachments %RecordPage{resource_type: :attachment, records: []}

  defstruct [
    :content,
    :channel_id,
    :author_id,
    :author_name,
    :thread_id,
    :message_id,
    :provider,
    :person,
    routing_context: %RoutingContext{},
    is_dm: false,
    metadata: %{},
    content_filter: [],
    attachments: @empty_attachments
  ]

  @type t :: %__MODULE__{
          content: String.t(),
          channel_id: String.t(),
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          thread_id: String.t() | nil,
          message_id: String.t() | integer() | nil,
          provider: atom() | String.t(),
          person: map() | nil,
          routing_context: RoutingContext.t(),
          is_dm: boolean(),
          metadata: map(),
          content_filter: [String.t()],
          attachments: RecordPage.t()
        }

  @doc "Builds the canonical incoming payload and injects telemetry dimensions into metadata."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    metadata = normalize_metadata(Map.get(attrs, :metadata) || Map.get(attrs, "metadata"))
    routing_context = normalize_routing_context(attrs, metadata)

    incoming = %__MODULE__{
      content: fetch_required!(attrs, :content),
      channel_id: fetch_required!(attrs, :channel_id),
      provider: fetch_required!(attrs, :provider),
      author_id: fetch_optional(attrs, :author_id),
      author_name: fetch_optional(attrs, :author_name),
      thread_id: fetch_optional(attrs, :thread_id),
      message_id: fetch_optional(attrs, :message_id),
      person: normalize_person(fetch_optional(attrs, :person)),
      routing_context: routing_context,
      is_dm: fetch_optional(attrs, :is_dm) == true,
      content_filter: normalize_content_filter(fetch_optional(attrs, :content_filter)),
      attachments: normalize_attachments(fetch_optional(attrs, :attachments)),
      metadata: metadata
    }

    put_telemetry_dimensions(incoming, attrs)
  end

  @doc "Returns the attachment records carried by the message, or `[]` when there are none."
  @spec attachment_records(t()) :: [Record.t()]
  def attachment_records(%__MODULE__{attachments: %RecordPage{records: records}}), do: records
  def attachment_records(%__MODULE__{}), do: []

  @doc "Replaces the message's attachment records, keeping the page wrapper intact."
  @spec put_attachment_records(t(), [Record.t()]) :: t()
  def put_attachment_records(%__MODULE__{attachments: page} = incoming, records)
      when is_list(records) do
    %{incoming | attachments: %{page | records: records}}
  end

  @doc """
  Finds an attachment by the id `attachment_notice/1` hands the model, or `nil`.

  The id is whatever the channel minted for the file, so it is compared as a string — the
  model echoes back the text it was shown.
  """
  @spec attachment_record(t(), String.t()) :: Record.t() | nil
  def attachment_record(%__MODULE__{} = incoming, id) when is_binary(id) do
    incoming |> attachment_records() |> Enum.find(&(to_string(&1.id) == id))
  end

  def attachment_record(%__MODULE__{}, _id), do: nil

  @doc """
  Describes the message's attachments for the model, or `nil` when there are none.

  This is application-injected context rather than anything the sender wrote, so it is
  persisted as a `system` message and merged into the prompt separately — never folded into
  `content`, which stays exactly what the person typed.

  Naming the file is not enough on its own: a model told only that an attachment exists left
  it alone. So each line spells out the call to make.
  """
  @spec attachment_notice(t()) :: String.t() | nil
  def attachment_notice(%__MODULE__{} = incoming) do
    case attachment_records(incoming) do
      [] -> nil
      records -> records |> Enum.map_join("\n", &describe_attachment/1) |> presence()
    end
  end

  # No materializing event means the channel handed over no way to reach the bytes, so the
  # model is told the file exists and cannot be opened rather than being sent after it.
  defp describe_attachment(%Record{materializing_event: nil} = record) do
    "[attachment: #{attachment_label(record)} — the sender's channel gave no way to fetch " <>
      "it, so it cannot be opened. Tell the user the file could not be received.]"
  end

  defp describe_attachment(%Record{} = record) do
    "[attachment: #{attachment_label(record)}. To read it, call the download_attachment " <>
      "tool with attachment_id=\"#{record.id}\".]"
  end

  defp attachment_label(%Record{name: name, mime_type: mime_type}) do
    case {name, mime_type} do
      {name, nil} when is_binary(name) -> name
      {name, mime} when is_binary(name) -> "#{name} (#{mime})"
      {_, mime} when is_binary(mime) -> "unnamed (#{mime})"
      _ -> "unnamed"
    end
  end

  defp presence(""), do: nil
  defp presence(text), do: text

  @doc "Returns the ZAQ Person ID carried by the incoming message, if resolved."
  @spec person_id(t()) :: integer() | nil
  def person_id(%__MODULE__{person: person}), do: ActorNormalizer.person_id(%{person: person})

  @doc """
  Returns the resolved person's full name, or `nil` when identity was not resolved.

  The payload `Zaq.People.IdentityResolver.person_payload/1` builds carries `full_name`;
  accepting either key shape keeps callers working with a person map rebuilt from JSON.
  """
  @spec person_name(t()) :: String.t() | nil
  def person_name(%__MODULE__{person: person}) when is_map(person) do
    case Map.get(person, :full_name) || Map.get(person, "full_name") do
      name when is_binary(name) -> if String.trim(name) == "", do: nil, else: name
      _ -> nil
    end
  end

  def person_name(%__MODULE__{}), do: nil

  @doc "Returns resolved team IDs from the incoming message person payload."
  @spec team_ids(t()) :: [integer()]
  def team_ids(%__MODULE__{person: person}), do: ActorNormalizer.team_ids(%{person: person})

  defp put_telemetry_dimensions(%__MODULE__{} = incoming, attrs) do
    dimensions = build_telemetry_dimensions(incoming, attrs)

    metadata =
      incoming.metadata
      |> Map.put("telemetry_dimensions", dimensions)

    %{incoming | metadata: metadata}
  end

  defp build_telemetry_dimensions(%__MODULE__{} = incoming, attrs) do
    provider = normalize_channel_type(incoming.provider)
    channel_config_id = resolve_channel_config_id(incoming, attrs)
    retrieval_channel_id = resolve_retrieval_channel_id(incoming, attrs)

    %{
      "channel_type" => provider,
      "channel_config_id" => channel_config_id,
      "retrieval_channel_id" => retrieval_channel_id,
      "provider" => to_string(incoming.provider),
      "channel_id" => incoming.channel_id
    }
  end

  defp resolve_channel_config_id(%__MODULE__{routing_context: context}, attrs) do
    value =
      context.channel_config_id ||
        fetch_optional(attrs, :channel_config_id) ||
        Map.get(attrs, "channel_config_id")

    normalize_channel_config_id(value)
  end

  defp resolve_retrieval_channel_id(%__MODULE__{routing_context: context}, attrs) do
    value = context.retrieval_channel_id || fetch_optional(attrs, :retrieval_channel_id)
    normalize_channel_config_id(value)
  end

  defp normalize_channel_config_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "unknown"
      val -> val
    end
  end

  defp normalize_channel_config_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_channel_config_id(_), do: "unknown"

  defp normalize_channel_type(:web), do: "bo"
  defp normalize_channel_type(:email), do: "email:imap"
  defp normalize_channel_type(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_channel_type(provider) when is_binary(provider) do
    case provider do
      "web" -> "bo"
      "email" -> "email:imap"
      other -> other
    end
  end

  defp normalize_channel_type(_), do: "api"

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp normalize_routing_context(attrs, metadata) do
    attrs
    |> fetch_optional(:routing_context)
    |> maybe_merge_legacy_routing_context(attrs, metadata)
    |> RoutingContext.normalize()
  end

  defp maybe_merge_legacy_routing_context(nil, attrs, metadata) do
    %{
      channel_config_id:
        fetch_optional(attrs, :channel_config_id) ||
          Map.get(metadata, "channel_config_id") || Map.get(metadata, :channel_config_id),
      retrieval_channel_id:
        fetch_optional(attrs, :retrieval_channel_id) ||
          Map.get(metadata, "retrieval_channel_id") || Map.get(metadata, :retrieval_channel_id)
    }
  end

  defp maybe_merge_legacy_routing_context(context, _attrs, _metadata), do: context

  defp normalize_person(person), do: ActorNormalizer.person(%{person: person})

  defp normalize_content_filter(list) when is_list(list) do
    Enum.filter(list, &is_binary/1)
  end

  defp normalize_content_filter(_), do: []

  # Callers hand attachments over either already paged or as a bare record list, since a
  # channel adapter builds records long before anything cares about pagination.
  defp normalize_attachments(%RecordPage{} = page), do: page

  defp normalize_attachments(records) when is_list(records),
    do: %RecordPage{@empty_attachments | records: Enum.filter(records, &match?(%Record{}, &1))}

  defp normalize_attachments(_), do: @empty_attachments

  defp fetch_required!(attrs, key) do
    if Map.has_key?(attrs, key) || Map.has_key?(attrs, Atom.to_string(key)) do
      fetch_optional(attrs, key)
    else
      raise ArgumentError, "missing required key #{inspect(key)} for Incoming.new/1"
    end
  end

  defp fetch_optional(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
