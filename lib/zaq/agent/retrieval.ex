defmodule Zaq.Agent.Retrieval do
  @moduledoc """
  Query rewriting agent.

  Takes a user question (plus optional conversation history) and rewrites it
  into one or more search queries via LLM, returning structured JSON.

  Uses DB-managed system prompt (`retrieval` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.LLM`.
  """

  require Logger

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.{History, LLM}
  alias Zaq.Agent.PromptTemplate

  @doc """
  Rewrites a user question into structured search queries via LLM.

  ## Options

    * `:system_prompt` — override the DB prompt (useful for tests).
      Defaults to the active `"retrieval"` prompt template.
    * `:history` — conversation history (map of `{timestamp, %{"body" => ..., "type" => ...}}`).

  Returns `{:ok, decoded_json}` on success.
  """
  def ask(question, opts \\ []) do
    Logger.info("Retrieval: Received question: #{question}")

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        PromptTemplate.get_active!("retrieval")
      end)

    history =
      Keyword.get(opts, :history, [])
      |> History.build()

    gen_opts =
      LLM.generation_opts()
      |> Keyword.put(:system_prompt, system_prompt)
      |> maybe_add_json_mode(history)

    Logger.info(
      "Retrieval: Processing question json_mode=#{LLM.supports_json_mode?() and history == []} history_length=#{length(history)}"
    )

    messages =
      if question && question != "" do
        history ++ [Context.user(question)]
      else
        history
      end

    result =
      try do
        Generation.generate_text(LLM.build_model_spec(), messages, gen_opts)
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, response} ->
        case normalized_text(Response.text(response)) do
          nil ->
            reason = "Failed to process question: Empty assistant response content"
            Logger.error("Retrieval failed: #{reason}")
            {:error, reason}

          content ->
            decode_retrieval_content(content)
        end

      {:error, reason} ->
        reason = "Failed to process question: #{inspect(reason)}"
        Logger.error("Retrieval failed: #{reason}")
        {:error, reason}
    end
  end

  # Extracts raw JSON from a response that may be wrapped in markdown code fences
  # or surrounded by prose (e.g. llama3.2 tends to wrap JSON in ```json ... ```).
  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/s, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      nil -> text
    end
  end

  defp decode_retrieval_content(content) do
    case content |> extract_json() |> Jason.decode() do
      {:ok, answer} ->
        {:ok, answer}

      {:error, decode_error} ->
        reason = "Failed to process question: #{Exception.message(decode_error)}"
        Logger.error("Retrieval failed: #{reason}")
        {:error, reason}
    end
  end

  # Some providers (e.g. Novita) return null content when json_response is active
  # and history contains non-JSON assistant messages. Disabling JSON mode when
  # history is present is safe — extract_json/1 handles JSON embedded in free-form text.
  defp normalized_text(nil), do: nil

  defp normalized_text(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)

  defp maybe_add_json_mode(gen_opts, history) do
    if LLM.supports_json_mode?() and history == [] do
      Keyword.put(gen_opts, :provider_options, response_format: %{type: "json_object"})
    else
      gen_opts
    end
  end
end
