defmodule Zaq.Engine.Notifications.Notification do
  @moduledoc """
  The canonical notification struct for ZAQ's notification center.

  Use `build/1` to construct — never build the struct literal directly.
  `Notifications.notify/1` only accepts a validated `%Notification{}`.
  """

  @enforce_keys [:recipient_channels, :sender, :subject, :body]

  alias Zaq.Contracts.Record

  defstruct [
    :recipient_name,
    :recipient_ref,
    :html_body,
    recipient_channels: [],
    sender: "system",
    subject: nil,
    body: nil,
    attachments: [],
    metadata: %{}
  ]

  @type channel :: %{
          optional(:channel_config_id) => pos_integer() | nil,
          platform: String.t(),
          identifier: String.t()
        }

  @type recipient_ref :: {:user, integer()} | {:person, integer()} | nil

  @type t :: %__MODULE__{
          recipient_channels: [channel()],
          recipient_name: String.t() | nil,
          recipient_ref: recipient_ref(),
          sender: String.t(),
          subject: String.t(),
          body: String.t(),
          html_body: String.t() | nil,
          attachments: [Record.t()],
          metadata: map()
        }

  @doc """
  Builds and validates a `%Notification{}` struct.

  Required fields: `subject`, `body`.
  Optional: `recipient_channels` (defaults to `[]`), `sender` (defaults to `"system"`),
  `recipient_name`, `recipient_ref`, `html_body`, `metadata`.

  Validation rules:
  - `subject` and `body` must be non-blank strings
  - Each channel must have a non-empty `:platform` and `:identifier`
  - Empty `recipient_channels` is valid

  Returns `{:ok, %Notification{}}` or `{:error, reason}`.
  """
  @spec build(map()) :: {:ok, t()} | {:error, String.t()}
  def build(attrs) when is_map(attrs) do
    with :ok <- validate_subject(attrs),
         :ok <- validate_body(attrs),
         :ok <- validate_channels(attrs),
         {:ok, attachments} <- normalize_attachments(Map.get(attrs, :attachments, [])) do
      notification = %__MODULE__{
        recipient_channels: Map.get(attrs, :recipient_channels, []),
        recipient_name: Map.get(attrs, :recipient_name),
        recipient_ref: Map.get(attrs, :recipient_ref),
        sender: Map.get(attrs, :sender, "system"),
        subject: Map.get(attrs, :subject),
        body: Map.get(attrs, :body),
        html_body: Map.get(attrs, :html_body),
        attachments: attachments,
        metadata: Map.get(attrs, :metadata, %{})
      }

      {:ok, notification}
    end
  end

  defp normalize_attachments(records) when is_list(records) and length(records) <= 100 do
    records
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Record.from_map(value) do
        {:ok, %Record{kind: :file} = record} -> {:cont, {:ok, [record | acc]}}
        _ -> {:halt, {:error, "attachments must contain signed file Records"}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp normalize_attachments(_), do: {:error, "attachments must be a list of at most 100 Records"}

  defp validate_subject(attrs) do
    case Map.get(attrs, :subject) do
      s when is_binary(s) and s != "" -> :ok
      _ -> {:error, "subject is required and must be a non-blank string"}
    end
  end

  defp validate_body(attrs) do
    case Map.get(attrs, :body) do
      b when is_binary(b) and b != "" -> :ok
      _ -> {:error, "body is required and must be a non-blank string"}
    end
  end

  defp validate_channels(attrs) do
    channels = Map.get(attrs, :recipient_channels, [])

    invalid =
      Enum.any?(channels, fn ch ->
        platform = Map.get(ch, :platform)
        identifier = Map.get(ch, :identifier)

        config_id = Map.get(ch, :channel_config_id)

        not (is_binary(platform) and platform != "" and is_binary(identifier) and identifier != "" and
               (is_nil(config_id) or (is_integer(config_id) and config_id > 0)))
      end)

    if invalid do
      {:error, "each recipient_channel must have a non-empty :platform and :identifier"}
    else
      :ok
    end
  end
end
