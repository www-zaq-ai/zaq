defmodule Zaq.Engine.Notifications.Notification do
  @moduledoc """
  The canonical notification struct for ZAQ's notification center.

  Use `build/1` to construct — never build the struct literal directly.
  `Notifications.notify/1` only accepts a validated `%Notification{}`.
  """

  @enforce_keys [:recipient_channels, :sender, :subject, :body]

  defstruct [
    :recipient_name,
    :recipient_ref,
    :html_body,
    recipient_channels: [],
    sender: "system",
    subject: nil,
    body: nil,
    metadata: %{}
  ]

  @type channel :: %{
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
         :ok <- validate_channels(attrs) do
      notification = %__MODULE__{
        recipient_channels: Map.get(attrs, :recipient_channels, []),
        recipient_name: Map.get(attrs, :recipient_name),
        recipient_ref: Map.get(attrs, :recipient_ref),
        sender: Map.get(attrs, :sender, "system"),
        subject: Map.get(attrs, :subject),
        body: Map.get(attrs, :body),
        html_body: Map.get(attrs, :html_body),
        metadata: Map.get(attrs, :metadata, %{})
      }

      {:ok, notification}
    end
  end

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

        not (is_binary(platform) and platform != "" and is_binary(identifier) and identifier != "")
      end)

    if invalid do
      {:error, "each recipient_channel must have a non-empty :platform and :identifier"}
    else
      :ok
    end
  end
end
