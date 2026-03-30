defmodule Zaq.Agent.LLMRunner do
  @moduledoc false

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Utils.ChainResult

  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) when is_list(opts) do
    llm_config = Keyword.fetch!(opts, :llm_config)
    system_prompt = Keyword.get(opts, :system_prompt)
    history = Keyword.get(opts, :history, [])
    question = Keyword.get(opts, :question, "")
    error_prefix = Keyword.get(opts, :error_prefix, "Failed to run LLM request")

    try do
      chain =
        LLMChain.new!(%{llm: ChatOpenAI.new!(llm_config)})
        |> maybe_add_system_message(system_prompt)
        |> maybe_add_history(history)
        |> maybe_add_user_message(question)

      case LLMChain.run(chain) do
        {:ok, _updated_chain} = ok ->
          ok

        {:error, _chain, error} ->
          {:error, "#{error_prefix}: #{format_error(error)}"}

        {:error, error} ->
          {:error, "#{error_prefix}: #{format_error(error)}"}
      end
    rescue
      e -> {:error, "#{error_prefix}: #{Exception.message(e)}"}
    end
  end

  @spec content(map()) :: String.t()
  def content(chain) do
    case ChainResult.to_string(chain) do
      {:ok, text} -> text
      {:error, _chain, _err} -> ContentPart.parts_to_string(chain.last_message.content)
    end
  end

  defp maybe_add_system_message(chain, prompt) when is_binary(prompt) and prompt != "",
    do: LLMChain.add_message(chain, Message.new_system!(prompt))

  defp maybe_add_system_message(chain, _), do: chain

  defp maybe_add_history(chain, history) when is_list(history) and history != [],
    do: LLMChain.add_messages(chain, history)

  defp maybe_add_history(chain, _), do: chain

  defp maybe_add_user_message(chain, question) when is_binary(question) and question != "",
    do: LLMChain.add_message(chain, Message.new_user!(question))

  defp maybe_add_user_message(chain, _), do: chain

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(%{reason: reason}) when is_binary(reason), do: reason
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)
end
