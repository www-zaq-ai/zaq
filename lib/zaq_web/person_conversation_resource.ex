defmodule ZaqWeb.PersonConversationResource do
  @moduledoc """
  Loads Engine-gated People resources for HTTP responses and source preview modals.

  Current source authorization runs through GetDocument on Channels. Only the fresh
  returned Record is materialized. Captured trace artifacts inherit the already
  authorized conversation access and are returned without interpreting historical
  Record metadata. Engine descriptors and signed handles remain server-side.
  """
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Contracts.Record
  alias Zaq.Materialization
  alias Zaq.NodeRouter

  @doc "Loads an authoritative Engine descriptor with the current authenticated actor."
  @spec load(:source | :artifact, map(), module()) :: {:ok, map()} | {:error, term()}
  def load(op, resource, router \\ NodeRouter) do
    resolve(op, resource, router)
  rescue
    _ -> {:error, :not_found}
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp resolve(:source, %{kind: :source, document_reference: reference, actor: actor}, router) do
    context = %{actor: actor, node_router: router}

    with {:ok, params} <- document_params(reference),
         {:ok, original} <- get_document(params, context),
         {:ok, record} <- materialize(original, context),
         {:ok, bytes} <- decode(record) do
      {:ok,
       %{
         content: bytes,
         name: record.name || original.name || "Source",
         mime_type: record.mime_type || original.mime_type
       }}
    end
  end

  defp resolve(:artifact, %{kind: :record, record: record}, _router), do: {:ok, record}

  defp resolve(_, _, _), do: {:error, :not_found}

  # Canonical identities are joined without URL encoding. Preserve the entire
  # provider document ID, including slashes, and never infer a config.
  defp document_params(source) when is_binary(source) do
    case String.split(source, "/", parts: 4) do
      ["data_source", provider, config, id] -> reference_params(provider, config, id)
      _ -> {:error, :not_found}
    end
  end

  defp document_params(_), do: {:error, :not_found}

  defp reference_params(provider, config, id)
       when is_binary(provider) and provider != "" and is_binary(id) and id != "" and
              ((is_binary(config) and config != "") or (is_integer(config) and config > 0)),
       do: {:ok, %{provider: provider, config_id: to_string(config), document_id: id}}

  defp reference_params(_, _, _), do: {:error, :not_found}

  defp get_document(params, context) do
    case Jido.Exec.run(GetDocument, params, context) do
      {:ok, %{record: %Record{} = record}} -> {:ok, record}
      {:ok, %{record: %Record{} = record}, _effects} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  defp materialize(%Record{content: content} = record, _) when is_binary(content),
    do: {:ok, record}

  defp materialize(%Record{materialization_handle: handle}, context) when is_binary(handle) do
    with {:ok, %{record: %Record{} = record}} <-
           Materialization.materialize(handle, context, "Source unavailable"),
         do: {:ok, record}
  end

  defp materialize(_, _), do: {:error, :not_found}

  defp decode(%Record{content: content, attributes: %{"encoding" => "base64"}})
       when is_binary(content), do: Base.decode64(content)

  defp decode(%Record{content: content}) when is_binary(content), do: {:ok, content}
  defp decode(_), do: {:error, :not_found}
end
