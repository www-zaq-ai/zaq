defmodule Zaq.TestSupport.LiveRAGBench do
  @moduledoc """
  Helpers for the `:benchmark_liverag` integration test.

  Loads the normalized LiveRAG data from `priv/bench/liverag/` and provisions
  **real** AI config through the production **ZAQ Router** path
  (`Zaq.UserPortal.Provisioner.provision_with_key/1`), so the benchmark exercises
  ZAQ's real pipeline against the real LiteLLM gateway. A single router key wires
  both LLM and embedding config (see `Zaq.Agent.ZAQRouter` defaults).

  The benchmark is excluded by default (see `test/test_helper.exs`) and skips
  itself when the key or data files are absent, so it never runs in normal CI.

  ## Env vars

    * `BENCH_LIVERAG_ROUTER_KEY` — **required.** The LiteLLM API key for the ZAQ
      Router gateway. Provisions credential + LLM + embedding config.
    * `BENCH_LIVERAG_ROUTER_URL` — optional gateway base URL (TEMP local default
      `http://localhost:4020`; prod is `https://llm.zaq.ai`). Overrides the
      `:litellm_base_url` that `config/test.exs` stubs to `http://litellm.test`.
  """

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System.LLMConfig
  alias Zaq.UserPortal.Provisioner

  # TEMP (per Jad): local ZAQ Router runs on :4020; prod default is
  # "https://llm.zaq.ai". Revert before merge. Override with BENCH_LIVERAG_ROUTER_URL.
  @default_router_url "http://localhost:4020"
  @source_prefix "liverag:"

  @dir Path.join([File.cwd!(), "priv", "bench", "liverag"])

  @doc "Absolute path to the benchmark data directory."
  def dir, do: @dir

  @doc """
  Reads the 970 source documents. Returns `{:ok, [%{doc_id, content}]}` or
  `{:error, :missing}` if the file hasn't been built (`mix zaq.bench.liverag.build`).
  """
  def docs, do: read_jsonl(Path.join(@dir, "docs.jsonl"))

  @doc "Reads the 895 questions. Same return contract as `docs/0`."
  def questions, do: read_jsonl(Path.join(@dir, "questions.jsonl"))

  defp read_jsonl(path) do
    if File.exists?(path) do
      rows =
        path
        |> File.stream!()
        |> Stream.map(&Jason.decode!/1)
        |> Enum.to_list()

      {:ok, rows}
    else
      {:error, :missing}
    end
  end

  @doc "The ZAQ Router key from `BENCH_LIVERAG_ROUTER_KEY`, or `nil` when unset."
  def router_key do
    case System.get_env("BENCH_LIVERAG_ROUTER_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc "The ZAQ Router gateway URL (override or `#{@default_router_url}`)."
  def router_url, do: System.get_env("BENCH_LIVERAG_ROUTER_URL") || @default_router_url

  @doc """
  Provisions real AI config via the production ZAQ Router path and removes the
  `Req.Test` embedding stub so calls hit the real gateway.

  Points `:litellm_base_url` at the real gateway, then calls
  `Provisioner.provision_with_key/1` — wiring the "ZAQ Router" credential plus
  LLM + embedding config exactly as user-portal onboarding does.

  Returns `{:ok, %{credential: cred, endpoint: url}}` or `{:skip, reason}`.
  Restores the stubbed gateway URL + embedding stub via `on_exit/1`.
  """
  def setup_real_ai! do
    case router_key() do
      nil ->
        {:skip, "BENCH_LIVERAG_ROUTER_KEY not set — skipping real-credential benchmark"}

      key ->
        point_at_real_gateway()
        bypass_embedding_stub()

        {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: key})
        maybe_override_llm_model()

        # The chunks-table dimension is managed by the corpus manager (it resets
        # the table when building). Just report the provisioned embedding identity.
        cfg = Zaq.System.get_embedding_config()

        {:ok,
         %{
           credential: credential,
           endpoint: router_url(),
           model: cfg.model,
           dimension: cfg.dimension
         }}
    end
  end

  # Optional `BENCH_LIVERAG_LLM_MODEL` — repoint the chat model (used for query
  # rewriting, answering, and the judge) at one your gateway actually serves.
  # Defaults to ZAQRouter.default_chat_model (openai/gpt-oss-120b).
  defp maybe_override_llm_model do
    case System.get_env("BENCH_LIVERAG_LLM_MODEL") do
      model when is_binary(model) and model != "" ->
        cfg = Zaq.System.get_llm_config()

        %LLMConfig{}
        |> LLMConfig.changeset(%{credential_id: cfg.credential_id, model: model})
        |> Zaq.System.save_llm_config()

      _ ->
        :ok
    end
  end

  # config/test.exs stubs :litellm_base_url to http://litellm.test; provisioning
  # reads it as the ZAQ Router endpoint, so point it at the real gateway first.
  defp point_at_real_gateway do
    original = Application.get_env(:zaq, :litellm_base_url)
    Application.put_env(:zaq, :litellm_base_url, router_url())
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:zaq, :litellm_base_url, original) end)
  end

  # Drops the Req.Test plug configured in config/test.exs so the Embedding.Client
  # makes a real HTTP call; restores it after the test.
  defp bypass_embedding_stub do
    original = Application.get_env(:zaq, Zaq.Embedding.Client)
    Application.put_env(:zaq, Zaq.Embedding.Client, req_options: [])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:zaq, Zaq.Embedding.Client, original) end)
  end

  # ---------------------------------------------------------------------------
  # Scoring helpers — retrieval recall (pure) + claim-coverage (LLM judge)
  # ---------------------------------------------------------------------------

  @doc """
  Optional `BENCH_LIVERAG_LIMIT` — run only the first N questions (smoke run).
  Returns `:all` when unset.
  """
  def limit do
    case System.get_env("BENCH_LIVERAG_LIMIT") do
      n when is_binary(n) and n != "" -> String.to_integer(n)
      _ -> :all
    end
  end

  @doc ~s|Maps a chunk source ("liverag:<doc_id>") back to its doc_id, else `nil`.|
  def source_to_doc_id(@source_prefix <> doc_id), do: doc_id
  def source_to_doc_id(_), do: nil

  @doc "Source string ZAQ stores for a LiveRAG doc — keeps load + scoring in sync."
  def doc_source(doc_id), do: @source_prefix <> doc_id

  @doc """
  Retrieval recall: fraction of `supporting_doc_ids` present in `retrieved_doc_ids`.
  Returns `nil` when there are no supporting docs (excluded from the mean).
  """
  def recall(retrieved_doc_ids, supporting_doc_ids) do
    support = MapSet.new(supporting_doc_ids)

    case MapSet.size(support) do
      0 ->
        nil

      n ->
        hits =
          retrieved_doc_ids
          |> MapSet.new()
          |> MapSet.intersection(support)
          |> MapSet.size()

        hits / n
    end
  end

  @doc """
  LLM-judge claim coverage: fraction of the answer's `direct` + `useful` claims
  entailed by `answer`. Uses the configured (ZAQ Router) LLM. Returns a float in
  `0.0..1.0`, or `nil` if there are no claims / the judge call fails.
  """
  def judge_claim_coverage(question, answer, claims) do
    target = claim_list(claims, "direct") ++ claim_list(claims, "useful")

    case target do
      [] -> nil
      claim_texts -> run_judge(question, answer, claim_texts)
    end
  end

  # Claims come from JSON (string keys).
  defp claim_list(claims, key), do: Map.get(claims, key, [])

  defp run_judge(question, answer, claim_texts) do
    cfg = Zaq.System.get_llm_config()
    gen_opts = cfg |> ProviderSpec.generation_opts() |> Keyword.delete(:top_p)
    prompt = judge_prompt(question, answer, claim_texts)

    with {:ok, response} <-
           Generation.generate_text(ProviderSpec.build(cfg), [Context.user(prompt)], gen_opts),
         text when is_binary(text) <- Response.text(response),
         {:ok, %{"covered" => covered}} when is_integer(covered) <- decode_judge(text) do
      min(covered, length(claim_texts)) / length(claim_texts)
    else
      _ -> nil
    end
  end

  defp judge_prompt(question, answer, claim_texts) do
    numbered =
      claim_texts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {c, i} -> "#{i}. #{c}" end)

    """
    You are grading a RAG answer. Count how many of the reference claims are
    supported (entailed) by the ANSWER. A claim counts only if the ANSWER states
    or clearly implies it.

    QUESTION:
    #{question}

    ANSWER:
    #{answer}

    REFERENCE CLAIMS (#{length(claim_texts)}):
    #{numbered}

    Respond ONLY with JSON: {"covered": <integer 0..#{length(claim_texts)}>}
    """
  end

  defp decode_judge(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> Jason.decode(json)
      _ -> :error
    end
  end
end
