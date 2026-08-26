defmodule ZaqWeb.PreviewReference do
  @moduledoc """
  Signed BO preview references for materialized file content.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.ExternalSource
  alias ZaqWeb.Endpoint

  @salt "bo-preview-reference"
  @max_age_seconds 15 * 60

  @spec sign_record(Record.t(), map()) :: String.t() | nil
  def sign_record(%Record{materialization_handle: handle} = record, current_user)
      when is_binary(handle) do
    Phoenix.Token.sign(Endpoint, @salt, %{
      "v" => 1,
      "type" => "record",
      "user_id" => user_id(current_user),
      "source" => source(record),
      "handle" => handle,
      "filename" => filename(record),
      "mime_type" => record.mime_type,
      "size" => record.size,
      "modified_at" => encode_datetime(record.modified_at)
    })
  end

  def sign_record(_record, _current_user), do: nil

  @spec verify(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify(token, current_user) when is_binary(token) do
    with {:ok, %{"user_id" => token_user_id} = payload} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age_seconds),
         true <- token_user_id == user_id(current_user) || {:error, :invalid_preview_reference} do
      {:ok, payload}
    end
  end

  def verify(_token, _current_user), do: {:error, :invalid_preview_reference}

  defp source(%Record{} = record) do
    if ExternalSource.external?(record) do
      ExternalSource.source(record)
    else
      attr(record, "source") || record.path || record.id
    end
  end

  defp filename(%Record{name: name}) when is_binary(name) and name != "",
    do: name

  defp filename(%Record{} = record) do
    value = record.path || record.id

    if is_binary(value), do: Path.basename(value), else: "file"
  end

  defp attr(%Record{attributes: attrs}, key) when is_map(attrs), do: Map.get(attrs, key)
  defp attr(_record, _key), do: nil

  defp user_id(%{id: id}), do: id
  defp user_id(%{"id" => id}), do: id
  defp user_id(_user), do: nil

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil
end
