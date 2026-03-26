defmodule Zaq.Embedding.Client do
  @moduledoc """
  Generic OpenAI-compatible embedding HTTP client.

  Posts to any `/embeddings` endpoint that follows the OpenAI API format.
  Works with Scaleway, OpenAI, Ollama, vLLM, LocalAI, and any other
  compatible provider.

  Uses `Req` for HTTP (already a ZAQ dependency).

  ## Configuration

  Embedding settings are managed via the back-office UI at `/bo/system-config`
  and persisted in the database. The application env is kept in sync
  automatically via `Zaq.System.apply_embedding_to_app_env/0`.

  ## Testing

  In `config/test.exs`, add:

      config :zaq, Zaq.Embedding.Client,
        endpoint: "http://localhost",
        api_key: "",
        model: "test-model",
        dimension: 1536,
        req_options: [plug: {Req.Test, Zaq.Embedding.Client}]

  Then in tests, use `Req.Test.stub/2` to mock responses.
  """

  require Logger

  @doc """
  Generates an embedding vector for the given text.

  ## Options

    * `:model` — override the configured model for this call

  ## Examples

      iex> Zaq.Embedding.Client.embed("Hello world")
      {:ok, [0.123, -0.456, ...]}

      iex> Zaq.Embedding.Client.embed("Hello", model: "nomic-embed-text")
      {:ok, [0.789, ...]}
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    model = Keyword.get(opts, :model, model())
    url = endpoint() <> "/embeddings"

    headers = build_headers()

    body = %{
      model: model,
      input: text
    }

    req_opts =
      [url: url, json: body, headers: headers, receive_timeout: 60_000]
      |> Keyword.merge(req_options())

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, "Unexpected response format: #{inspect(body)}"}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Embedding API error (#{status}): #{inspect(body)}")
        {:error, "API error (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("Embedding HTTP request failed: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Returns the configured embedding dimension.
  Used by Ecto migrations and vector operations.
  """
  @spec dimension() :: pos_integer()
  def dimension, do: config(:dimension, 3584)

  @doc "Returns the configured embedding endpoint."
  def endpoint, do: config(:endpoint)

  @doc "Returns the configured embedding API key."
  def api_key, do: config(:api_key, "")

  @doc "Returns the configured embedding model."
  def model, do: config(:model, "bge-multilingual-gemma2")

  # -- Private --

  defp build_headers do
    key = api_key()

    if key != nil and key != "" do
      [{"authorization", "Bearer #{key}"}]
    else
      []
    end
  end

  defp req_options do
    config(:req_options, [])
  end

  defp config(key, default \\ nil) do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
