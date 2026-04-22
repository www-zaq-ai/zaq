# Exec Plan: Replace LangChain with Jido AI / ReqLLM in Retrieval, Answering, and ChunkTitle

**Date**: 2026-04-22  
**Branch**: `feat/jido-ai-llm-migration`  
**Status**: COMPLETE (Phases 1–7 done, tests green, precommit passing)

---

## What Changes

`Retrieval` and `Answering` are today built on LangChain: `LLMChain`, `ChatOpenAI`,
`ChatAnthropic`, `LangChain.Message`. Their public interfaces (`Retrieval.ask/2`,
`Answering.ask/2`) stay the same. Only the LLM call internals change.

`ChunkTitle` is a simple single-turn call — same story.

**Architecture decision**: `Retrieval` and `Answering` are stateless per-request LLM
calls that receive explicit conversation history each call. They do not need persistent
`Jido.AgentServer` processes or ReAct multi-step reasoning. The correct Jido AI
migration for these is to call `ReqLLM.Generation.generate_text/3` directly — the same
primitive that `Jido.AI.Agent` uses internally. `Pipeline.run` is **not touched**.

`LLMRunner`, `History` (LangChain-based), and `LLM.build_model/1` are all removed
once the above three modules no longer depend on them.

---

## Credential Path (unchanged)

Both `Retrieval` and `Answering` read system-wide config from
`Zaq.System.get_llm_config/0` which resolves the `AIProviderCredential` to give
`provider`, `endpoint`, `api_key`, `model`, etc. That path is not touched.

For ReqLLM, `api_key` overrides the default lookup order and `base_url` overrides
the provider's default endpoint. Both are confirmed fields in `ReqLLM.Keys.get!/2`
and `ReqLLM.Provider.Options.effective_base_url/3`.

---

## LangChain ↔ ReqLLM Mapping

### Model spec

```elixir
# LangChain (current)
ChatOpenAI.new!(%{model: "...", temperature: ..., endpoint: cfg.endpoint <> cfg.path})
ChatAnthropic.new!(%{model: "...", temperature: ..., api_key: ...})

# ReqLLM (new)
%{provider: :openai, id: cfg.model, api_key: cfg.api_key, base_url: cfg.endpoint}
# Anthropic has no base_url — uses its own default
%{provider: :anthropic, id: cfg.model, api_key: cfg.api_key}
# IMPORTANT: base_url must be cfg.endpoint ONLY — do NOT append cfg.path
# (ReqLLM appends the /chat/completions path itself via provider module)
```

### Messages / History

```elixir
# LangChain (current)
LangChain.Message.new_user!(msg)
LangChain.Message.new_assistant!(msg)

# ReqLLM (new)
ReqLLM.Context.user(msg)
ReqLLM.Context.assistant(msg)
# NOTE: ReqLLM.Message.content is [ContentPart], NOT a plain string.
#       Always use the Context helpers — never build ReqLLM.Message structs directly.
```

### LLM call

```elixir
# LangChain (current)
{:ok, updated_chain} = LLMRunner.run(llm_config: config, system_prompt: prompt,
                                     history: [LangChain.Message.t()], question: q)
{:ok, content} = LLMRunner.content_result(updated_chain)

# ReqLLM (new)
messages = history_messages ++ [ReqLLM.Context.user(question)]
{:ok, response} = ReqLLM.Generation.generate_text(model_spec, messages,
  system_prompt: prompt,
  temperature: cfg.temperature,
  top_p: cfg.top_p
)
content = ReqLLM.Response.text(response)   # String.t() | nil
```

### JSON mode (Retrieval only)

```elixir
# LangChain (current)
Map.put(config, :json_response, true)

# ReqLLM (new) — OpenAI-compatible providers only
Keyword.put(opts, :provider_options, [response_format: %{type: "json_object"}])
# NOTE: Anthropic does NOT support response_format — already in @unsupported_parameters
#       LLM.supports_json_mode?() guards this, same as today
```

### Token usage (Answering only)

```elixir
# LangChain (current)
bot_response = List.last(updated_chain.messages)
usage = Map.get(bot_response.metadata, :usage) || %{}
prompt_tokens = usage_value(usage, :input)     # checks :input and "input" keys
completion_tokens = usage_value(usage, :output)

# ReqLLM (new)
usage = ReqLLM.Response.usage(response) || %{}
# usage is %{input_tokens: integer, output_tokens: integer, total_tokens: integer, ...}
prompt_tokens = usage[:input_tokens] |> as_int()
completion_tokens = usage[:output_tokens] |> as_int()
```

### Logprobs / Confidence

Logprobs are not supported in `req_llm` (confirmed: zero mentions in jido_ai,
Anthropic provider has `response_format` in `@unsupported_parameters`, OpenAI
provider has no logprobs handling). `confidence_score` becomes `nil` for all answers.
No crash — telemetry already gates on `is_number/1`. Track in tech-debt-tracker.

---

## Phase 1 — Migrate `Zaq.Agent.History` (< ½ day)

**File**: `lib/zaq/agent/history.ex`

```elixir
# Before
alias LangChain.Message
...
Message.new_assistant!(msg)
Message.new_user!(msg)
# @spec build(map() | list()) :: [Message.t()]

# After
alias ReqLLM.Context
...
Context.assistant(msg)
Context.user(msg)
# @spec build(map() | list()) :: [ReqLLM.Message.t()]
```

The sorting logic, key parsing, and JSON encoding of non-binary body values are
unchanged. Only the two message constructors and alias change.

---

## Phase 2 — Migrate `Zaq.Agent.LLM` (½ day)

**File**: `lib/zaq/agent/llm.ex`

Remove the two LangChain aliases. Delete `build_model/1`. Add `build_model_spec/0`
and `generation_opts/0`. Remove `chat_config/0` (only callers are Retrieval and
Answering, which are migrated in Phases 3–4).

```elixir
# Remove these aliases entirely
alias LangChain.ChatModels.ChatAnthropic
alias LangChain.ChatModels.ChatOpenAI

# Remove: build_model/1 (ChatOpenAI.new!/ChatAnthropic.new!)
# Remove: chat_config/0 (builds endpoint <> path — wrong for ReqLLM)

# Add:
@doc """
Returns a ReqLLM inline model spec map from the system LLM config.

Uses cfg.endpoint directly as base_url — do NOT append cfg.path.
Anthropic uses its own API URL; no base_url needed.
"""
def build_model_spec do
  cfg = Zaq.System.get_llm_config()
  %{provider: String.to_atom(cfg.provider), id: cfg.model, api_key: cfg.api_key || ""}
  |> maybe_put_base_url(cfg)
end

defp maybe_put_base_url(spec, %{provider: "anthropic"}), do: spec
defp maybe_put_base_url(spec, %{endpoint: url}) when is_binary(url) and url != "",
  do: Map.put(spec, :base_url, url)
defp maybe_put_base_url(spec, _), do: spec

@doc "Sampling opts for ReqLLM generation calls."
def generation_opts do
  cfg = Zaq.System.get_llm_config()
  [temperature: cfg.temperature, top_p: cfg.top_p]
end
```

`endpoint/0`, `api_key/0`, `model/0`, `temperature/0`, `top_p/0`,
`supports_logprobs?/0`, `supports_json_mode?/0` are all kept unchanged — they're
still used by callers.

---

## Phase 3 — Migrate `Retrieval.ask/2` (½ day)

**File**: `lib/zaq/agent/retrieval.ex`

```elixir
# Current call (LangChain via LLMRunner)
llm_config = LLM.chat_config() |> maybe_add_json_mode()
{:ok, updated_chain} = RuntimeDeps.llm_runner().run(
  llm_config: llm_config, system_prompt: system_prompt,
  history: history, question: question, error_prefix: "..."
)
{:ok, content} = RuntimeDeps.llm_runner().content_result(updated_chain)

# New call (ReqLLM directly)
model_spec = LLM.build_model_spec()
gen_opts = LLM.generation_opts()
          |> maybe_add_json_mode()
          |> Keyword.put(:system_prompt, system_prompt)
messages = history ++ [ReqLLM.Context.user(question)]
{:ok, response} = ReqLLM.Generation.generate_text(model_spec, messages, gen_opts)
content = ReqLLM.Response.text(response)
```

`maybe_add_json_mode/1` changes from `Map.put(config, :json_response, true)` to
`Keyword.put(opts, :provider_options, [response_format: %{type: "json_object"}])`.

Remove the `alias Zaq.Agent.{History, LLM}` — add `alias ReqLLM.Context` (for
`Context.user` if building manually, though history already returns `[ReqLLM.Message.t()]`).
Remove `alias Zaq.RuntimeDeps`. The `decode_retrieval_content/1` and `extract_json/1`
helpers are **unchanged**.

---

## Phase 4 — Migrate `Answering.ask/2` (½ day)

**File**: `lib/zaq/agent/answering.ex`

```elixir
# Current (LangChain via LLMRunner)
include_confidence = Keyword.get(opts, :include_confidence, LLM.supports_logprobs?())
llm_config = LLM.chat_config() |> maybe_add_logprobs(include_confidence)
{:ok, updated_chain} = RuntimeDeps.llm_runner().run(
  llm_config: llm_config, system_prompt: system_prompt,
  history: history, question: question, error_prefix: "..."
)
{:ok, answer} = RuntimeDeps.llm_runner().content_result(updated_chain)
bot_response = List.last(updated_chain.messages)
usage = Map.get(bot_response.metadata, :usage) || %{}
prompt_tokens = usage_value(usage, :input)
completion_tokens = usage_value(usage, :output)
confidence_score = maybe_confidence_score(bot_response, include_confidence)

# New (ReqLLM directly)
model_spec = LLM.build_model_spec()
gen_opts = LLM.generation_opts() |> Keyword.put(:system_prompt, system_prompt)
messages = history ++ (if question, do: [ReqLLM.Context.user(question)], else: [])
{:ok, response} = ReqLLM.Generation.generate_text(model_spec, messages, gen_opts)
answer = ReqLLM.Response.text(response)
usage = ReqLLM.Response.usage(response) || %{}
prompt_tokens = usage[:input_tokens] |> as_int()
completion_tokens = usage[:output_tokens] |> as_int()
confidence_score = nil  # logprobs not supported in req_llm
```

Remove `include_confidence`, `maybe_add_logprobs/2`, `maybe_confidence_score/2`.
Remove `alias Zaq.Agent.{History, LLM, LogprobsAnalyzer}`. Remove
`alias Zaq.RuntimeDeps`.

`usage_value/2` helper is no longer needed (field names differ); replace with
direct `usage[:input_tokens] |> as_int()` inline. `as_int/1`,
`maybe_total_tokens/2`, `log_token_usage/2`, `emit_answer_telemetry/2`, and all
`normalize_result/1` / `no_answer?/1` / `clean_answer/1` public helpers are
**unchanged**.

---

## Phase 5 — Migrate `ChunkTitle` off LangChain (½ day)

**File**: `lib/zaq/agent/chunk_title.ex`

Single-turn title generation call — same pattern as Phases 3–4.

```elixir
# Before
RuntimeDeps.llm_runner().run(llm_config: config, system_prompt: prompt, question: text)

# After
model_spec = LLM.build_model_spec()
gen_opts = LLM.generation_opts() |> Keyword.put(:system_prompt, prompt)
{:ok, response} = ReqLLM.Generation.generate_text(model_spec, [ReqLLM.Context.user(text)], gen_opts)
title = ReqLLM.Response.text(response)
```

---

## Phase 6 — Remove `LLMRunner` and `History` (< ½ day)

Once Phases 3–5 are complete, nothing calls `LLMRunner` or `LangChain.Message`.

- Delete `lib/zaq/agent/llm_runner.ex`
- Delete `lib/zaq/agent/llm_runner_behaviour.ex`
- Delete `lib/zaq/agent/history.ex` **only if** there are no remaining callers;
  `History.entry_key/2` may still be used by Engine — verify with `mix grep`
- Remove `llm_runner/0` from `Zaq.RuntimeDeps`
- `mix compile` — any remaining `LangChain.*` aliases surface as errors

---

## Phase 7 — Remove `:langchain` from `mix.exs` (< 1 hour)

1. Delete `{:langchain, "~> 0.8"}` from `mix.exs`
2. `mix deps.unlock langchain`
3. `mix deps.get && mix compile` — confirm clean

---

## Phase 8 — Test suite (1 day)

- [ ] `mix test test/zaq/agent/retrieval_test.exs`
- [ ] `mix test test/zaq/agent/answering_test.exs`
- [ ] `mix test test/zaq/agent/chunk_title_test.exs`
- [ ] `mix test test/zaq/agent/` — full suite
- [ ] `mix precommit`

---

## Phase 9 — Update docs (½ day)

- [ ] `docs/services/agent.md` — update `llm_runner.ex`, `retrieval.ex`, `answering.ex`,
  `history.ex` descriptions
- [ ] Key design decisions: replace "LangChain via ChatOpenAI" entry

---

## Logprobs / Confidence Score Tech Debt

`confidence_score` becomes `nil` for all answers after migration. No crash.
Fix belongs in a `req_llm` PR: add logprobs to OpenAI provider → surface in
`provider_meta` → `jido_ai` passes `provider_meta` through action results.

---

## Files Changed

| File | Change |
|---|---|
| `lib/zaq/agent/history.ex` | Replace `LangChain.Message` with `ReqLLM.Context` helpers |
| `lib/zaq/agent/llm.ex` | Remove LangChain aliases + `build_model/1` + `chat_config/0`; add `build_model_spec/0` + `generation_opts/0` |
| `lib/zaq/agent/retrieval.ex` | Swap LLMRunner for `ReqLLM.Generation.generate_text/3` |
| `lib/zaq/agent/answering.ex` | Swap LLMRunner for `ReqLLM.Generation.generate_text/3`; swap LangChain usage for `ReqLLM.Response.usage/1` |
| `lib/zaq/agent/chunk_title.ex` | Swap LLMRunner for `ReqLLM.Generation.generate_text/3` |
| `lib/zaq/agent/llm_runner.ex` | DELETED |
| `lib/zaq/agent/llm_runner_behaviour.ex` | DELETED |
| `mix.exs` | Remove `{:langchain, "~> 0.8"}` |

**Not touched**: `pipeline.ex`, `executor.ex`, `factory.ex`, `server_manager.ex`,
`retrieval.ex` public interface, `answering.ex` public interface, all channels.

**`history.ex` note**: `entry_key/2` may still be used outside the agent pipeline
(e.g., Engine or test helpers). Verify callers before deleting the file; if needed,
keep the file but remove the `LangChain.Message` dependency and `build/1`.

---

## Estimated Total: 3–4 days
