defmodule Zaq.Channels.Web.Message do
  @moduledoc """
  Normalized web transport message accepted from BO and widget adapters.

  This is an adapter-boundary value, not the canonical Engine message. WebBridge
  validates it and translates it to `Zaq.Engine.Messages.Incoming`. Trusted actor,
  capability and delivery data belongs in `Zaq.Channels.Web.Context`, never here.
  """

  alias Zaq.Channels.Web.Validation

  @allowed_fields [
    :request_id,
    :message_id,
    :content,
    :timestamp,
    :channel,
    :mode,
    :conversation_id,
    :author_id,
    :author_name,
    :attachments,
    :prompt_context
  ]

  @enforce_keys [:request_id, :message_id, :content, :timestamp, :channel, :mode]
  defstruct @enforce_keys ++
              [:conversation_id, :author_id, :author_name, :prompt_context, attachments: []]

  @type mode :: :async | :sync
  @type t :: %__MODULE__{
          request_id: String.t(),
          message_id: String.t(),
          content: String.t(),
          timestamp: DateTime.t(),
          channel: String.t(),
          mode: mode(),
          conversation_id: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          prompt_context: String.t() | nil,
          attachments: list()
        }

  @doc "Builds a normalized web message from trusted adapter-decoded fields."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Validation.reject_unknown_fields(attrs, @allowed_fields),
         {:ok, request_id} <-
           Validation.identifier(Validation.fetch(attrs, :request_id), :request_id,
             required: true
           ),
         {:ok, message_id} <-
           Validation.identifier(Validation.fetch(attrs, :message_id), :message_id,
             required: true
           ),
         {:ok, content} <-
           Validation.required_text(Validation.fetch(attrs, :content), :content, 100_000),
         {:ok, timestamp} <- timestamp(Validation.fetch(attrs, :timestamp)),
         {:ok, channel} <-
           Validation.identifier(Validation.fetch(attrs, :channel), :channel, required: true),
         {:ok, mode} <- mode(Validation.fetch(attrs, :mode)),
         {:ok, conversation_id} <-
           Validation.identifier(Validation.fetch(attrs, :conversation_id), :conversation_id),
         {:ok, author_id} <-
           Validation.identifier(Validation.fetch(attrs, :author_id), :author_id),
         {:ok, author_name} <-
           Validation.identifier(Validation.fetch(attrs, :author_name), :author_name),
         {:ok, attachments} <-
           Validation.list(Validation.fetch(attrs, :attachments), :attachments),
         {:ok, prompt_context} <- prompt_context(Validation.fetch(attrs, :prompt_context)) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         message_id: message_id,
         content: content,
         timestamp: timestamp,
         channel: channel,
         mode: mode,
         conversation_id: conversation_id,
         author_id: author_id,
         author_name: author_name,
         prompt_context: prompt_context,
         attachments: attachments
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :message}}

  defp prompt_context(nil), do: {:ok, nil}
  defp prompt_context(content), do: Validation.required_text(content, :prompt_context, 100_000)

  defp timestamp(%DateTime{time_zone: "Etc/UTC"} = timestamp), do: {:ok, timestamp}
  defp timestamp(_timestamp), do: {:error, {:invalid_field, :timestamp}}

  defp mode(mode) when mode in [:async, "async"], do: {:ok, :async}
  defp mode(mode) when mode in [:sync, "sync"], do: {:ok, :sync}
  defp mode(_mode), do: {:error, {:invalid_field, :mode}}
end
