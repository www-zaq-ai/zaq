defmodule ZaqWeb.PrivateResourceResponse do
  @moduledoc "Private authenticated byte responses with safe filenames, MIME types and no caching."
  import Plug.Conn
  @inline_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)

  @doc "Serves already-authorized bytes; callers own authentication and resource ACLs."
  def send(conn, resource) do
    type =
      if resource.mime_type in @inline_types,
        do: resource.mime_type,
        else: "application/octet-stream"

    disposition = if type in @inline_types, do: "inline", else: "attachment"
    filename = safe_filename(resource.name)

    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "sandbox")
    |> send_resp(:ok, resource.content)
  end

  defp safe_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1F\x7F"\\]+/u, "_")
    |> case do
      "" -> "artifact"
      sanitized -> sanitized
    end
  end

  defp safe_filename(_), do: "artifact"
end
