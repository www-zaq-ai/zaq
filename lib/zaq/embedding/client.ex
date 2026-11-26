defmodule Zaq.Embedding.Client do
  @moduledoc """
  Generic OpenAI-compatible embedding HTTP client.

  Posts to any `/embeddings` endpoint that follows the OpenAI API format.
  Works with Scaleway, OpenAI, Ollama, vLLM, LocalAI, and any other
  compatible provider.

  Uses `Req` for HTTP (already a ZAQ dependency).

  ## Configuration

  Embedding settings are managed via the back-office UI at `/bo/system-config`
  and persisted in the database. All values are read directly from the
  database via `Zaq.System.get_embedding_config/0`.

  ## Testing

  In `config/test.exs`, configure Req.Test stubbing:

      config :zaq, Zaq.Embedding.Client,
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
    cfg = Zaq.System.get_embedding_config()
    model = Keyword.get(opts, :model, cfg.model)

    case request(text, cfg, model, []) do
      {:ok, %Req.Response{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:error, "Unexpected response format: #{inspect(response_body)}"}

      {:ok, %Req.Response{status: 429, headers: response_headers, body: response_body}} ->
        delay_seconds = rate_limit_delay_seconds(response_headers)

        Logger.warning(
          "Embedding API rate limited (429). Retrying in #{delay_seconds}s. Body: #{inspect(response_body)}"
        )

        {:error, {:rate_limited, delay_seconds, %{status: 429, body: response_body}}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.error("Embedding API error (#{status}): #{inspect(response_body)}")
        {:error, "API error (#{status}): #{inspect(response_body)}"}

      {:error, reason} ->
        Logger.error("Embedding HTTP request failed: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Embeds an ordered list of validated texts with one snapshot of the configured
  provider. Each result has a one-based input index. On a rate limit, later
  items are returned as not attempted with the same retry delay.

  Responses are checked against the configured dimension and contain no raw
  provider errors. `embed/2` retains its existing single-vector contract.
  """
  @spec embed_batch([String.t()]) :: [map()]
  def embed_batch(texts) when is_list(texts) do
    cfg = Zaq.System.get_embedding_config()

    {results, _retry_delay} =
      texts
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, &embed_batch_item(&1, &2, cfg))

    results
  end

  @doc """
  Returns the configured embedding dimension.
  Used by Ecto migrations and vector operations.
  """
  @spec dimension() :: pos_integer()
  def dimension, do: Zaq.System.get_embedding_config().dimension

  @doc "Returns the configured embedding endpoint."
  def endpoint, do: Zaq.System.get_embedding_config().endpoint

  @doc "Returns the configured embedding API key."
  def api_key, do: Zaq.System.get_embedding_config().api_key || ""

  @doc "Returns the configured embedding model."
  def model, do: Zaq.System.get_embedding_config().model

  # -- Private --

  defp request(text, cfg, model, overrides) do
    headers =
      if cfg.api_key != nil and cfg.api_key != "" do
        [{"authorization", "Bearer #{cfg.api_key}"}]
      else
        []
      end

    opts =
      [
        url: cfg.endpoint <> "/embeddings",
        json: %{model: model, input: text},
        headers: headers,
        receive_timeout: 60_000
      ]
      |> Keyword.merge(req_options())
      |> Keyword.merge(overrides)

    Req.post(opts)
  end

  defp embed_batch_item({_text, index}, delay, _cfg) when is_integer(delay) do
    {%{index: index, status: "not_attempted", error: "rate_limited", retry_after_seconds: delay},
     delay}
  end

  defp embed_batch_item({text, index}, nil, cfg) do
    response = request(text, cfg, cfg.model, retry: false)

    case batch_response(response, cfg) do
      {:ok, attributes} ->
        {Map.merge(attributes, %{index: index, status: "ok"}), nil}

      {:error, %{retry_after_seconds: delay} = error} ->
        {Map.merge(error, %{index: index, status: "error"}), delay}

      {:error, error} ->
        {Map.merge(error, %{index: index, status: "error"}), nil}
    end
  end

  defp batch_response({:ok, %Req.Response{status: 200, body: body}}, cfg) do
    with %{"data" => [%{"embedding" => vector} = row]} <- body,
         true <- Map.get(row, "index", 0) === 0,
         model when is_binary(model) <- Map.get(body, "model", cfg.model),
         true <- String.trim(model) != "",
         true <- is_list(vector) and Enum.all?(vector, &is_number/1) do
      validate_vector(vector, model, cfg.dimension)
    else
      _ -> {:error, %{error: "invalid_response"}}
    end
  end

  defp batch_response({:ok, %Req.Response{status: 429, headers: headers}}, _cfg) do
    {:error,
     %{
       error: "rate_limited",
       http_status: 429,
       retry_after_seconds: rate_limit_delay_seconds(headers)
     }}
  end

  defp batch_response({:ok, %Req.Response{status: status}}, _cfg),
    do: {:error, %{error: "provider_error", http_status: status}}

  defp batch_response({:error, _reason}, _cfg), do: {:error, %{error: "transport_error"}}

  defp validate_vector(vector, model, dimension) do
    if dimension > 0 and length(vector) == dimension do
      {:ok, %{vector: vector, model: model, dimension: dimension}}
    else
      {:error, %{error: "invalid_dimension"}}
    end
  end

  defp rate_limit_delay_seconds(headers) do
    with nil <- header_value(headers, "retry-after"),
         nil <- header_value(headers, "ratelimit-reset"),
         nil <- header_value(headers, "x-ratelimit-reset") do
      60
    else
      value when is_binary(value) ->
        parse_rate_limit_delay(value)
    end
  end

  defp parse_rate_limit_delay(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {parsed, ""} when parsed >= 0 ->
        normalize_delay_seconds(parsed)

      _ ->
        parse_http_date_delay(trimmed)
    end
  end

  defp normalize_delay_seconds(parsed) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    if parsed > now do
      max(parsed - now, 0)
    else
      parsed
    end
  end

  defp parse_http_date_delay(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {:error, _reason} ->
        60

      :bad_date ->
        60

      datetime_tuple ->
        delay_seconds =
          datetime_tuple
          |> :calendar.datetime_to_gregorian_seconds()
          |> Kernel.-(:calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}))
          |> Kernel.-(DateTime.utc_now() |> DateTime.to_unix())

        max(delay_seconds, 0)
    end
  end

  defp header_value(headers, key) when is_map(headers) do
    headers
    |> Map.get(String.downcase(key))
    |> normalize_header_value()
  end

  defp header_value(headers, key) when is_list(headers) do
    key_downcase = String.downcase(key)

    headers
    |> Enum.find_value(fn
      {header_key, header_value} when is_binary(header_key) ->
        if String.downcase(header_key) == key_downcase do
          normalize_header_value(header_value)
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _key), do: nil

  defp normalize_header_value([value | _]) when is_binary(value), do: value
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(_), do: nil

  defp req_options do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
