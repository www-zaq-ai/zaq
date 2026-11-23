defmodule Zaq.Channels.TransportRequirements do
  @moduledoc """
  Attachment transport constraints and capabilities for a selected connection.

  Byte limits default to `:unresolved`; `:not_applicable` denotes an inapplicable
  ceiling. The transfer mode describes transport capabilities; ZAQ owns delivery
  policy.

  `resolve/2` derives requirements from a supplied capability snapshot and selected
  connection. It performs no lookup, acquisition, planning or delivery.
  """

  alias Zaq.ConnectorConfig.FileSettings

  @enforce_keys [:transfer_mode, :max_attachments_per_message]
  defstruct [
    :transfer_mode,
    :max_attachments_per_message,
    failure_policy: :continue,
    max_attachment_bytes: :unresolved,
    max_attachment_bytes_per_message: :unresolved,
    max_encoded_message_bytes: :unresolved,
    max_upload_request_bytes: :unresolved,
    supports_threads: false,
    supports_attachment_edits: false
  ]

  @type limit :: pos_integer() | :not_applicable | :unresolved
  @type t :: %__MODULE__{
          failure_policy: :continue | :abort,
          transfer_mode: :upload_then_publish | :send_with_attachments,
          max_attachments_per_message: pos_integer(),
          max_attachment_bytes: limit(),
          max_attachment_bytes_per_message: limit(),
          max_encoded_message_bytes: limit(),
          max_upload_request_bytes: limit(),
          supports_threads: boolean(),
          supports_attachment_edits: boolean()
        }

  @doc """
  Returns requirements or unsupported, unavailable, invalid-configuration, or
  unresolved-capability errors. Optional unknown byte limits remain unresolved;
  successful resolution requires a declared transfer mode and positive count.
  Failure policy comes only from the selected connection's file settings.
  """
  @spec resolve(term(), map()) :: {:ok, t()} | {:error, term()}
  def resolve(_, %{kind: kind}) when kind in [:data_source, "data_source"],
    do: {:error, :unsupported}

  def resolve(snapshot, connection) when is_map(snapshot) and is_map(connection) do
    cond do
      not FileSettings.supported?(snapshot, :file) -> {:error, :unsupported}
      is_nil(FileSettings.metadata(snapshot)) -> {:error, :capabilities_unavailable}
      true -> derive(snapshot, connection)
    end
  end

  def resolve(_, _), do: {:error, :capabilities_unavailable}

  defp derive(snapshot, connection) do
    metadata = FileSettings.metadata(snapshot)
    settings = FileSettings.from_connection(connection)

    case FileSettings.effective_limits(settings, snapshot) do
      {:ok, limits} -> build(snapshot, metadata, settings, limits)
      {:error, errors} -> {:error, {:invalid_configuration, errors}}
    end
  end

  defp build(snapshot, metadata, settings, limits) do
    case Map.get(metadata, :transfer_mode) do
      mode when mode in [:upload_then_publish, :send_with_attachments] ->
        attributes =
          Map.merge(limits, %{
            transfer_mode: mode,
            failure_policy:
              if(Map.get(settings, "send_on_file_failure", true), do: :continue, else: :abort),
            supports_threads: FileSettings.supported?(snapshot, :threads),
            supports_attachment_edits: Map.get(metadata, :supports_attachment_edits) == true
          })

        {:ok, struct!(__MODULE__, attributes)}

      _ ->
        {:error, {:unresolved_capabilities, [:transfer_mode]}}
    end
  end
end
