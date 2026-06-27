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
  """

  @enforce_keys [:content, :channel_id, :provider]

  defstruct [
    :content,
    :channel_id,
    :author_id,
    :author_name,
    :thread_id,
    :message_id,
    :provider,
    :person,
    is_dm: false,
    metadata: %{},
    content_filter: []
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
          is_dm: boolean(),
          metadata: map(),
          content_filter: [String.t()]
        }

  @doc "Builds the canonical incoming payload and injects telemetry dimensions into metadata."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    metadata = normalize_metadata(Map.get(attrs, :metadata) || Map.get(attrs, "metadata"))

    incoming = %__MODULE__{
      content: fetch_required!(attrs, :content),
      channel_id: fetch_required!(attrs, :channel_id),
      provider: fetch_required!(attrs, :provider),
      author_id: fetch_optional(attrs, :author_id),
      author_name: fetch_optional(attrs, :author_name),
      thread_id: fetch_optional(attrs, :thread_id),
      message_id: fetch_optional(attrs, :message_id),
      person: normalize_person(fetch_optional(attrs, :person)),
      is_dm: fetch_optional(attrs, :is_dm) == true,
      content_filter: normalize_content_filter(fetch_optional(attrs, :content_filter)),
      metadata: metadata
    }

    put_telemetry_dimensions(incoming, attrs)
  end

  @doc "Returns the ZAQ Person ID carried by the incoming message, if resolved."
  @spec person_id(t()) :: integer() | nil
  def person_id(%__MODULE__{person: person}), do: person_field(person, :id)

  @doc "Returns resolved team IDs from the incoming message person payload."
  @spec team_ids(t()) :: [integer()]
  def team_ids(%__MODULE__{person: person}) do
    case person_field(person, :team_ids) do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp put_telemetry_dimensions(%__MODULE__{} = incoming, attrs) do
    dimensions = build_telemetry_dimensions(incoming, attrs)

    metadata =
      incoming.metadata
      |> Map.put("telemetry_dimensions", dimensions)

    %{incoming | metadata: metadata}
  end

  defp build_telemetry_dimensions(%__MODULE__{} = incoming, attrs) do
    provider = normalize_channel_type(incoming.provider)
    channel_config_id = resolve_channel_config_id(attrs, incoming.metadata)

    %{
      "channel_type" => provider,
      "channel_config_id" => channel_config_id,
      "provider" => to_string(incoming.provider),
      "channel_id" => incoming.channel_id
    }
  end

  defp resolve_channel_config_id(attrs, metadata) do
    value =
      fetch_optional(attrs, :channel_config_id) ||
        Map.get(metadata, "channel_config_id") ||
        Map.get(metadata, :channel_config_id)

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

  defp normalize_person(nil), do: nil

  defp normalize_person(person) when is_map(person) do
    id = person_field(person, :id)

    if is_nil(id) do
      nil
    else
      %{
        id: id,
        full_name: person_field(person, :full_name),
        team_ids: person_field(person, :team_ids) || []
      }
    end
  end

  defp normalize_person(_), do: nil

  defp person_field(person, key) when is_map(person) and is_atom(key) do
    Map.get(person, key) || Map.get(person, Atom.to_string(key))
  end

  defp person_field(_person, _key), do: nil

  defp normalize_content_filter(list) when is_list(list) do
    Enum.filter(list, &is_binary/1)
  end

  defp normalize_content_filter(_), do: []

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
