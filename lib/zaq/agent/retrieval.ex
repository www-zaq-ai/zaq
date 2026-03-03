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
  alias Zaq.Agent.LLM
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
    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        PromptTemplate.get_active!("retrieval").body
      end)

    history =
      Keyword.get(opts, :history, [])
      |> build_history()

    llm_config =
      LLM.chat_config()
      |> maybe_add_json_mode()

    Logger.info("Retrieval: Processing question with strict grounding")

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

    answer = ChainResult.to_string!(updated_chain) |> Jason.decode!()

    {:ok, answer}
  end

  defp build_history([]), do: []

  defp build_history(history) when is_map(history) do
    Enum.map(history, fn
      {_timestamp, %{"body" => msg, "type" => "bot"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_system!(msg)

      {_timestamp, %{"body" => msg, "type" => "user"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_user!(msg)
    end)
  end

  defp maybe_add_json_mode(config) do
    if LLM.supports_json_mode?() do
      Map.put(config, :json_response, true)
    else
      config
    end
  end
end
