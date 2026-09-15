defmodule Zaq.Ingestion.DocumentContent do
  @moduledoc """
  Authorized source-content reads on the Ingestion node. Resolves the current
  Person and document ACL before returning a stored materialization reference or
  legacy source bytes. It does not accept privilege flags or a BO user-shaped identity.
  """
  alias Zaq.Accounts.People
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Storage.FileExplorer

  @doc "Checks the current document ACL for a canonical source and literal Person."
  @spec authorize(term(), term()) :: :ok | {:error, :not_found}
  def authorize(source, person_id) do
    with {:ok, _document} <- authorized_document(source, person_id), do: :ok
  end

  @doc """
  Returns the authorized document's `materialization_handle`, `name` and `mime_type`
  for server-side redemption, or legacy `content` bytes with the same display fields.
  Handles must never be exposed to the browser. Options are retained for API compatibility.
  """
  @spec read(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(source, person_id, _opts \\ []) do
    with {:ok, document} <- authorized_document(source, person_id) do
      content(document)
    end
  end

  defp authorized_document(source, person_id) when is_integer(person_id) and person_id > 0 do
    with true <- is_binary(source) and source != "",
         person when not is_nil(person) <- People.get_person(person_id),
         %Document{} = document <- Document.get_by_source(source),
         true <- Permissions.can?(person, :read, document) do
      {:ok, document}
    else
      _ -> {:error, :not_found}
    end
  end

  defp authorized_document(_, _), do: {:error, :not_found}

  defp content(%Document{metadata: %{"materialization_handle" => handle}} = doc)
       when is_binary(handle) do
    {:ok,
     %{
       materialization_handle: handle,
       name: doc.title || Path.basename(doc.source),
       mime_type: "application/octet-stream"
     }}
  end

  defp content(%Document{} = doc) do
    with {:ok, path} <- FileExplorer.resolve_path(doc.source),
         {:ok, bytes} <- File.read(path) do
      {:ok,
       %{content: bytes, name: Path.basename(doc.source), mime_type: MIME.from_path(doc.source)}}
    else
      _ -> stored_content(doc)
    end
  end

  defp stored_content(%Document{content: content} = doc) when is_binary(content),
    do:
      {:ok,
       %{content: content, name: (doc.title || "Source") <> ".md", mime_type: "text/markdown"}}

  defp stored_content(_), do: {:error, :not_found}
end
