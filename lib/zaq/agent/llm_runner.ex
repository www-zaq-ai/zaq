defmodule Zaq.Agent.LLMRunner do
  @moduledoc false

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Utils.ChainResult
  alias Zaq.Agent.LLM

  @empty_content_log_ttl_ms 60_000
  @diag_table :zaq_llm_runner_diag

  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) when is_list(opts) do
    llm_config = Keyword.fetch!(opts, :llm_config)
    system_prompt = Keyword.get(opts, :system_prompt)
    history = Keyword.get(opts, :history, [])
    question = Keyword.get(opts, :question, "")
    error_prefix = Keyword.get(opts, :error_prefix, "Failed to run LLM request")

    try do
      chain =
        LLMChain.new!(%{llm: build_llm_model(llm_config)})
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
      e ->
        {:error, "#{error_prefix}: #{Exception.message(e)}"}
    end
  end

  @spec content(map()) :: String.t()
  def content(chain) do
    case content_result(chain) do
      {:ok, text} -> text
      {:error, _reason} -> ""
    end
  end

  @spec content_result(map()) :: {:ok, String.t()} | {:error, String.t()}
  def content_result(chain) do
    case safe_chain_to_string(chain) do
      {:ok, text} ->
        case normalized_text(text) do
          {:ok, normalized} -> {:ok, normalized}
          :error -> fallback_content_result(chain, :empty_chain_result_text)
        end

      _ ->
        fallback_content_result(chain, :chain_result_error)
    end
  end

  defp safe_chain_to_string(chain) do
    ChainResult.to_string(chain)
  rescue
    _ -> {:error, chain, :chain_to_string_failed}
  end

  defp fallback_content_to_string(%{last_message: %{content: content}}) do
    ContentPart.content_to_string(content)
  end

  defp fallback_content_to_string(_), do: nil

  defp fallback_content_result(chain, chain_result_status) do
    chain
    |> fallback_content_to_string()
    |> case do
      text ->
        case normalized_text(text) do
          {:ok, normalized} ->
            {:ok, normalized}

          :error ->
            maybe_log_empty_content(chain, chain_result_status)
            {:error, "Empty assistant response content"}
        end
    end
  end

  defp maybe_log_empty_content(chain, chain_result_status) do
    metadata = empty_content_metadata(chain, chain_result_status)
    :telemetry.execute([:zaq, :agent, :llm_runner, :empty_content], %{count: 1}, metadata)

    if should_log_empty_content?(metadata) do
      Logger.warning(
        "LLMRunner empty assistant content provider=#{metadata.provider} model=#{metadata.model} " <>
          "role=#{metadata.role} status=#{metadata.status} content_kind=#{metadata.content_kind} " <>
          "tool_calls_count=#{metadata.tool_calls_count} chain_result=#{metadata.chain_result_status}"
      )
    end
  end

  defp should_log_empty_content?(metadata) do
    key =
      {
        metadata.provider,
        metadata.model,
        metadata.role,
        metadata.status,
        metadata.content_kind,
        metadata.tool_calls_count,
        metadata.chain_result_status
      }

    now_ms = System.monotonic_time(:millisecond)

    case ensure_diag_table() do
      :undefined ->
        true

      table ->
        case :ets.lookup(table, key) do
          [] ->
            :ets.insert(table, {key, now_ms})
            true

          [{^key, previous_ms}] when now_ms - previous_ms >= @empty_content_log_ttl_ms ->
            :ets.insert(table, {key, now_ms})
            true

          _ ->
            false
        end
    end
  end

  defp ensure_diag_table do
    case :ets.whereis(@diag_table) do
      :undefined ->
        try do
          :ets.new(@diag_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          _ -> :ok
        end

        :ets.whereis(@diag_table)

      table ->
        table
    end
  end

  defp empty_content_metadata(chain, chain_result_status) do
    last_message = Map.get(chain, :last_message)
    llm = Map.get(chain, :llm)

    %{
      provider: llm_provider(llm),
      model: llm_model(llm),
      role: message_role(last_message),
      status: message_status(last_message),
      content_kind: content_kind(last_message),
      tool_calls_count: tool_calls_count(last_message),
      chain_result_status: chain_result_status
    }
  end

  defp llm_provider(nil), do: "unknown"
  defp llm_provider(%module{}), do: module |> Module.split() |> List.last()

  defp llm_model(%{model: model}) when is_binary(model), do: model
  defp llm_model(_), do: "unknown"

  defp message_role(%{role: role}) when is_atom(role), do: Atom.to_string(role)
  defp message_role(%{role: role}) when is_binary(role), do: role
  defp message_role(_), do: "unknown"

  defp message_status(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp message_status(%{status: status}) when is_binary(status), do: status
  defp message_status(_), do: "unknown"

  defp content_kind(%{content: nil}), do: "nil"
  defp content_kind(%{content: content}) when is_binary(content), do: "binary"
  defp content_kind(%{content: content}) when is_list(content), do: "list"
  defp content_kind(%{content: _}), do: "other"
  defp content_kind(_), do: "unknown"

  defp tool_calls_count(%{tool_calls: calls}) when is_list(calls), do: length(calls)
  defp tool_calls_count(_), do: 0

  defp normalized_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: :error, else: {:ok, text}
  end

  defp normalized_text(_), do: :error

  defp build_llm_model(config), do: LLM.build_model(config)

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
