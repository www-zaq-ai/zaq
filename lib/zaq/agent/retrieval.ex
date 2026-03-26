defmodule Zaq.Agent.Retrieval do
  @moduledoc """
  Query rewriting agent.

  Takes a user question (plus optional conversation history) and rewrites it
  into one or more search queries via LLM, returning structured JSON.

  Uses DB-managed system prompt (`retrieval` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.LLM`.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Utils.ChainResult
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

    llm_config =
      LLM.chat_config()
      |> maybe_add_json_mode()

    Logger.info("Retrieval: Processing question with strict grounding")

    try do
      {:ok, updated_chain} =
        LLMChain.new!(%{llm: ChatOpenAI.new!(llm_config)})
        |> LLMChain.add_message(Message.new_system!(system_prompt))
        |> then(fn chain ->
          if history != [], do: LLMChain.add_messages(chain, history), else: chain
        end)
        |> then(fn chain ->
          if question != "",
            do: LLMChain.add_message(chain, Message.new_user!(question)),
            else: chain
        end)
        |> LLMChain.run()

      answer = ChainResult.to_string!(updated_chain) |> extract_json() |> Jason.decode!()

      {:ok, answer}
    rescue
      e ->
        Logger.error("Retrieval failed: #{inspect(e)}")
        {:error, "Failed to process question: #{Exception.message(e)}"}
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

  defp maybe_add_json_mode(config) do
    if LLM.supports_json_mode?() do
      Map.put(config, :json_response, true)
    else
      config
    end
  end
end
