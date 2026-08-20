defmodule Zaq.Materialization.Handle do
  @moduledoc """
  Signed JSON-safe materialization handles.

  Handles describe how to rebuild a trusted runtime materialization request. They
  are integrity-protected locators, not authorization grants; callers redeem them
  with the current trusted execution context.
  """

  alias Plug.Crypto.{KeyGenerator, MessageVerifier}
  alias Zaq.Helpers

  @salt "zaq.materialization.handle"
  @version 1
  @payload_keys MapSet.new(["v", "type", "locator"])
  @semantic_type :materialization_handle

  @type verified :: %{type: String.t(), locator: map(), version: pos_integer()}

  @spec issue(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def issue(type, locator, opts \\ [])

  def issue(type, locator, opts) when is_binary(type) and is_map(locator) do
    with :ok <- validate_type(type),
         {:ok, payload} <- payload(type, locator) do
      {:ok, MessageVerifier.sign(Jason.encode!(payload), secret(opts))}
    end
  end

  def issue(_type, _locator, _opts), do: {:error, :invalid_materialization_handle}

  @spec verify(String.t(), keyword()) :: {:ok, verified()} | {:error, term()}
  def verify(handle, opts \\ [])

  def verify(handle, opts) when is_binary(handle) do
    with {:ok, encoded} <- verify_signature(handle, opts),
         {:ok, payload} <- Jason.decode(encoded),
         {:ok, verified} <- validate_payload(payload) do
      {:ok, verified}
    else
      :error -> {:error, :invalid_materialization_handle}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_handle, _opts), do: {:error, :invalid_materialization_handle}

  @doc """
  Returns the semantic Zoi type for materialization handles.

  The JSON shape remains a string; metadata lets agent-side processors distinguish
  handle fields from arbitrary strings without relying on field names.
  """
  @spec zoi_type(keyword()) :: Zoi.schema()
  def zoi_type(opts \\ []) do
    metadata =
      opts
      |> Keyword.get(:metadata, [])
      |> Keyword.put(:zaq_semantic_type, @semantic_type)

    opts
    |> Keyword.put(:metadata, metadata)
    |> Zoi.string()
  end

  @doc false
  @spec semantic_type() :: :materialization_handle
  def semantic_type, do: @semantic_type

  defp payload(type, locator) do
    payload = %{"v" => @version, "type" => type, "locator" => locator}

    case Jason.encode(payload) do
      {:ok, _} -> {:ok, payload}
      {:error, _reason} -> {:error, :invalid_materialization_locator}
    end
  end

  defp verify_signature(handle, opts) do
    case MessageVerifier.verify(handle, secret(opts)) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> {:error, :invalid_materialization_handle}
    end
  end

  defp validate_payload(%{"v" => @version, "type" => type, "locator" => locator} = payload)
       when is_binary(type) and is_map(locator) do
    with :ok <- validate_payload_keys(payload),
         :ok <- validate_type(type) do
      {:ok, %{type: type, locator: locator, version: @version}}
    end
  end

  defp validate_payload(%{"v" => _version}), do: {:error, :unsupported_materialization_handle}
  defp validate_payload(_payload), do: {:error, :invalid_materialization_handle}

  defp validate_payload_keys(payload) do
    keys = payload |> Map.keys() |> MapSet.new()

    if MapSet.equal?(keys, @payload_keys) do
      :ok
    else
      {:error, :invalid_materialization_handle}
    end
  end

  defp validate_type(type) do
    if Helpers.blank?(type) do
      {:error, :invalid_materialization_type}
    else
      :ok
    end
  end

  defp secret(opts) do
    key_base = Keyword.get(opts, :secret_key_base) || ZaqWeb.Endpoint.config(:secret_key_base)
    KeyGenerator.generate(key_base, @salt)
  end
end
