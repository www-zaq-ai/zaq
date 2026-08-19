defmodule Zaq.Contracts.RecordCapability do
  @moduledoc """
  Signs and verifies persisted communication-media source capabilities.

  The signature binds every field that controls fetching or model projection.
  Serialized Records may carry the signature, but never the signing secret.
  """

  alias Zaq.Contracts.Record

  @signature_key "source_signature"

  @doc "Signs a communication-media Record with the node-shared runtime secret."
  @spec sign!(Record.t()) :: Record.t()
  def sign!(%Record{} = record) do
    case secret() do
      {:ok, secret} -> put_signature(record, signature(record, secret))
      {:error, reason} -> raise ArgumentError, "cannot sign Record capability: #{inspect(reason)}"
    end
  end

  @doc "Verifies that a communication-media Record's fetch fields are unchanged."
  @spec verify(Record.t()) :: :ok | {:error, :invalid_record_capability}
  def verify(%Record{} = record) do
    with signature when is_binary(signature) <- source_signature(record),
         {:ok, secret} <- secret(),
         expected <- signature(record, secret),
         true <- byte_size(signature) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(signature, expected) do
      :ok
    else
      _ -> {:error, :invalid_record_capability}
    end
  end

  @doc "Verifies a capability and binds its source author to trusted execution context."
  @spec authorize(Record.t(), map()) ::
          :ok | {:error, :invalid_record_capability | :unauthorized_record_capability}
  def authorize(%Record{} = record, context) when is_map(context) do
    case verify(record) do
      :ok -> authorize_actor(record, context)
      {:error, :invalid_record_capability} = error -> error
    end
  end

  defp signature(record, secret) do
    record
    |> payload()
    |> then(&:crypto.mac(:hmac, :sha256, secret, &1))
    |> Base.url_encode64(padding: false)
  end

  defp payload(%Record{} = record) do
    attributes = record.attributes || %{}

    [
      "v1",
      record.id,
      record.kind,
      record.name,
      record.mime_type,
      record.size,
      attribute(attributes, "source_type"),
      attribute(attributes, "provider"),
      attribute(attributes, "source_id"),
      attribute(attributes, "channel_config_id"),
      attribute(attributes, "source_author_id"),
      attribute(attributes, "source_channel_id"),
      attribute(attributes, "source_message_id"),
      attribute(attributes, "encoding")
    ]
    |> Enum.map(&normalize/1)
    |> Jason.encode!()
  end

  defp put_signature(%Record{} = record, signature) do
    attributes = Map.put(record.attributes || %{}, @signature_key, signature)
    %{record | attributes: attributes}
  end

  defp source_signature(%Record{attributes: attributes}) when is_map(attributes),
    do: attribute(attributes, @signature_key)

  defp source_signature(%Record{}), do: nil

  defp attribute(attributes, key) do
    Map.get(attributes, key) ||
      attributes
      |> Map.to_list()
      |> Enum.find_value(fn
        {attribute_key, value} when is_atom(attribute_key) ->
          if Atom.to_string(attribute_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp normalize(nil), do: ""
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: to_string(value)

  defp authorize_actor(_record, %{skip_permissions: true}), do: :ok

  defp authorize_actor(%Record{attributes: attributes}, context) do
    expected = attribute(attributes || %{}, "source_author_id") |> normalize()
    actual = actor_id(context) |> normalize()

    if expected != "" and expected == actual,
      do: :ok,
      else: {:error, :unauthorized_record_capability}
  end

  defp actor_id(%{actor: actor}) when is_map(actor),
    do: Map.get(actor, :id) || Map.get(actor, "id")

  defp actor_id(%{incoming: incoming}) when is_map(incoming),
    do: Map.get(incoming, :author_id) || Map.get(incoming, "author_id")

  defp actor_id(_context), do: nil

  defp secret do
    endpoint_config = Application.get_env(:zaq, ZaqWeb.Endpoint, [])
    value = Keyword.get(endpoint_config, :secret_key_base)

    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, :missing_record_capability_secret}
  end
end
