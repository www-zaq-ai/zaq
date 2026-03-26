defmodule ZaqWeb.Live.BO.System.SystemConfigComponents do
  @moduledoc false
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ── Telemetry Panel ────────────────────────────────────────────────────

  attr :form, :any, required: true

  def telemetry_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Telemetry Collection</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Control infra event capture and minimum duration thresholds.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="telemetry-config-form"
          for={@form}
          phx-submit="save_telemetry"
          phx-change="validate_telemetry"
          class="space-y-5"
        >
          <div class="flex items-center justify-between py-2 border-b border-black/[0.05]">
            <div>
              <p class="font-mono text-[0.82rem] font-semibold text-black">
                Capture infra metrics
              </p>
              <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                Collect Phoenix request, Repo query, and Oban runtime metrics.
              </p>
            </div>
            <label class="relative inline-flex items-center cursor-pointer">
              <input type="hidden" name="telemetry_config[capture_infra_metrics]" value="false" />
              <input
                type="checkbox"
                name="telemetry_config[capture_infra_metrics]"
                value="true"
                checked={@form[:capture_infra_metrics].value in [true, "true"]}
                class="sr-only peer"
              />
              <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
              </div>
            </label>
          </div>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Request Duration Threshold (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[request_duration_threshold_ms]"
                value={@form[:request_duration_threshold_ms].value}
                phx-debounce="400"
                placeholder="0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:request_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Repo Query Threshold (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[repo_query_duration_threshold_ms]"
                value={@form[:repo_query_duration_threshold_ms].value}
                phx-debounce="400"
                placeholder="0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:repo_query_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                No-Answer Alert Threshold (%)
              </label>
              <input
                type="number"
                min="0"
                max="100"
                name="telemetry_config[no_answer_alert_threshold_percent]"
                value={@form[:no_answer_alert_threshold_percent].value}
                phx-debounce="400"
                placeholder="10"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:no_answer_alert_threshold_percent].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Conversations Response SLA (ms)
              </label>
              <input
                type="number"
                min="0"
                name="telemetry_config[conversation_response_sla_ms]"
                value={@form[:conversation_response_sla_ms].value}
                phx-debounce="400"
                placeholder="1500"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:conversation_response_sla_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div class="bg-[#fafafa] rounded-xl border border-black/5 px-4 py-3">
            <p class="font-mono text-[0.72rem] text-black/50 leading-relaxed">
              Thresholds are applied by the telemetry collector and Conversations dashboard alerts.
              Use <span class="font-semibold text-black/70">0</span> to capture every event.
            </p>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Telemetry Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── LLM Panel ─────────────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :providers, :list, required: true
  attr :model_options, :list, required: true
  attr :capabilities, :map, required: true
  attr :api_key_value, :string, default: ""

  def llm_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">LLM</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          OpenAI-compatible language model endpoint used for chat and retrieval.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="llm-config-form"
          for={@form}
          phx-submit="save_llm"
          phx-change="validate_llm"
          class="space-y-5"
        >
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Provider
              </label>
              <.searchable_select
                id="llm-provider-select"
                name="llm_config[provider]"
                value={@form[:provider].value}
                options={@providers}
                placeholder="Search providers..."
                empty_label="Custom"
              />
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Model
              </label>
              <.searchable_select
                :if={@model_options != []}
                id="llm-model-select"
                name="llm_config[model]"
                value={@form[:model].value}
                options={@model_options}
                placeholder="Search models..."
                empty_label="Select a model..."
              />
              <input
                :if={@model_options == []}
                type="text"
                name="llm_config[model]"
                value={@form[:model].value}
                phx-debounce="400"
                placeholder="llama-3.3-70b-instruct"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Endpoint
            </label>
            <input
              type="text"
              name="llm_config[endpoint]"
              value={@form[:endpoint].value}
              phx-debounce="400"
              placeholder="http://localhost:11434/v1"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
            />
            <p
              :for={{msg, _opts} <- @form[:endpoint].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {msg}
            </p>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              API Key
            </label>
            <div class="relative">
              <input
                type="password"
                name="llm_config[api_key]"
                value={@api_key_value}
                placeholder="Enter API key"
                autocomplete="new-password"
                phx-debounce="blur"
                id="llm-api-key-input"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 pr-10 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <button
                type="button"
                id="llm-api-key-show"
                phx-click={
                  JS.set_attribute({"type", "text"}, to: "#llm-api-key-input")
                  |> JS.add_class("hidden", to: "#llm-api-key-show")
                  |> JS.remove_class("hidden", to: "#llm-api-key-hide")
                }
                class="absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"
                  /><path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                  />
                </svg>
              </button>
              <button
                type="button"
                id="llm-api-key-hide"
                phx-click={
                  JS.set_attribute({"type", "password"}, to: "#llm-api-key-input")
                  |> JS.remove_class("hidden", to: "#llm-api-key-show")
                  |> JS.add_class("hidden", to: "#llm-api-key-hide")
                }
                class="hidden absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"
                  />
                </svg>
              </button>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Temperature
              </label>
              <input
                type="number"
                min="0"
                max="2"
                step="0.1"
                name="llm_config[temperature]"
                value={@form[:temperature].value}
                phx-debounce="400"
                placeholder="0.0"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:temperature].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Top-P
              </label>
              <input
                type="number"
                min="0.01"
                max="1"
                step="0.05"
                name="llm_config[top_p]"
                value={@form[:top_p].value}
                phx-debounce="400"
                placeholder="0.9"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:top_p].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="font-mono text-[0.82rem] font-semibold text-black">JSON Mode</p>
                  <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                    Force structured JSON output.
                  </p>
                </div>
                <label class="relative inline-flex items-center cursor-pointer shrink-0 ml-3">
                  <input type="hidden" name="llm_config[supports_json_mode]" value="false" />
                  <input
                    type="checkbox"
                    name="llm_config[supports_json_mode]"
                    value="true"
                    checked={@form[:supports_json_mode].value in [true, "true"]}
                    class="sr-only peer"
                  />
                  <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
                  </div>
                </label>
              </div>
              <p
                :if={
                  @capabilities.json_mode == false &&
                    @form[:supports_json_mode].value in [true, "true"]
                }
                class="font-mono text-[0.72rem] text-amber-600 mt-1"
              >
                Model doesn't support JSON mode — recommend turning off.
              </p>
            </div>
            <div>
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="font-mono text-[0.82rem] font-semibold text-black">Logprobs</p>
                  <p class="font-mono text-[0.72rem] text-black/40 mt-0.5">
                    Log-probability confidence scores.
                  </p>
                </div>
                <label class="relative inline-flex items-center cursor-pointer shrink-0 ml-3">
                  <input type="hidden" name="llm_config[supports_logprobs]" value="false" />
                  <input
                    type="checkbox"
                    name="llm_config[supports_logprobs]"
                    value="true"
                    checked={@form[:supports_logprobs].value in [true, "true"]}
                    class="sr-only peer"
                  />
                  <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm">
                  </div>
                </label>
              </div>
              <p
                :if={
                  @capabilities.logprobs == false && @form[:supports_logprobs].value in [true, "true"]
                }
                class="font-mono text-[0.72rem] text-amber-600 mt-1"
              >
                Model doesn't support logprobs — recommend turning off.
              </p>
            </div>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save LLM Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Embedding Panel ───────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :providers, :list, required: true
  attr :model_options, :list, required: true
  attr :api_key_value, :string, default: ""

  def embedding_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Embedding</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          OpenAI-compatible embedding endpoint used for vector search.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="embedding-config-form"
          for={@form}
          phx-submit="save_embedding"
          phx-change="validate_embedding"
          class="space-y-5"
        >
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Provider
              </label>
              <.searchable_select
                id="embedding-provider-select"
                name="embedding_config[provider]"
                value={@form[:provider].value}
                options={@providers}
                placeholder="Search providers..."
                empty_label="Custom"
              />
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Model
              </label>
              <.searchable_select
                :if={@model_options != []}
                id="embedding-model-select"
                name="embedding_config[model]"
                value={@form[:model].value}
                options={@model_options}
                placeholder="Search models..."
                empty_label="Select a model..."
              />
              <input
                :if={@model_options == []}
                type="text"
                name="embedding_config[model]"
                value={@form[:model].value}
                phx-debounce="400"
                placeholder="bge-multilingual-gemma2"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Endpoint
            </label>
            <input
              type="text"
              name="embedding_config[endpoint]"
              value={@form[:endpoint].value}
              phx-debounce="400"
              placeholder="http://localhost:11434/v1"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
            />
            <p
              :for={{msg, _opts} <- @form[:endpoint].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {msg}
            </p>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              API Key
            </label>
            <div class="relative">
              <input
                type="password"
                name="embedding_config[api_key]"
                value={@api_key_value}
                placeholder="Enter API key"
                autocomplete="new-password"
                phx-debounce="blur"
                id="embedding-api-key-input"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 pr-10 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <button
                type="button"
                id="embedding-api-key-show"
                phx-click={
                  JS.set_attribute({"type", "text"}, to: "#embedding-api-key-input")
                  |> JS.add_class("hidden", to: "#embedding-api-key-show")
                  |> JS.remove_class("hidden", to: "#embedding-api-key-hide")
                }
                class="absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"
                  /><path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                  />
                </svg>
              </button>
              <button
                type="button"
                id="embedding-api-key-hide"
                phx-click={
                  JS.set_attribute({"type", "password"}, to: "#embedding-api-key-input")
                  |> JS.remove_class("hidden", to: "#embedding-api-key-show")
                  |> JS.add_class("hidden", to: "#embedding-api-key-hide")
                }
                class="hidden absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"
                  />
                </svg>
              </button>
            </div>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Dimension
            </label>
            <input
              type="number"
              min="1"
              name="embedding_config[dimension]"
              value={@form[:dimension].value}
              phx-debounce="400"
              placeholder="3584"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
            />
            <p
              :for={{msg, _opts} <- @form[:dimension].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {msg}
            </p>
          </div>
          <div class="bg-amber-50 rounded-xl border border-amber-200 px-4 py-3">
            <p class="font-mono text-[0.72rem] text-amber-700 leading-relaxed">
              Changing the dimension requires re-creating the chunks table and re-ingesting all documents.
            </p>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Embedding Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Image to Text Panel ───────────────────────────────────────────────

  attr :form, :any, required: true
  attr :providers, :list, required: true
  attr :model_options, :list, required: true
  attr :api_key_value, :string, default: ""

  def image_to_text_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Image to Text</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Vision model endpoint used to extract text from images and PDFs during ingestion.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="image-to-text-config-form"
          for={@form}
          phx-submit="save_image_to_text"
          phx-change="validate_image_to_text"
          class="space-y-5"
        >
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Provider
              </label>
              <.searchable_select
                id="image-to-text-provider-select"
                name="image_to_text_config[provider]"
                value={@form[:provider].value}
                options={@providers}
                placeholder="Search providers..."
                empty_label="Custom"
              />
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Model
              </label>
              <.searchable_select
                :if={@model_options != []}
                id="image-to-text-model-select"
                name="image_to_text_config[model]"
                value={@form[:model].value}
                options={@model_options}
                placeholder="Search models..."
                empty_label="Select a model..."
              />
              <input
                :if={@model_options == []}
                type="text"
                name="image_to_text_config[model]"
                value={@form[:model].value}
                phx-debounce="400"
                placeholder="pixtral-12b-2409"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              API URL
            </label>
            <input
              type="text"
              name="image_to_text_config[api_url]"
              value={@form[:api_url].value}
              phx-debounce="400"
              placeholder="http://localhost:11434/v1"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
            />
            <p
              :for={{msg, _opts} <- @form[:api_url].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {msg}
            </p>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              API Key
            </label>
            <div class="relative">
              <input
                type="password"
                name="image_to_text_config[api_key]"
                value={@api_key_value}
                placeholder="Enter API key"
                autocomplete="new-password"
                phx-debounce="blur"
                id="image-to-text-api-key-input"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 pr-10 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <button
                type="button"
                id="image-to-text-api-key-show"
                phx-click={
                  JS.set_attribute({"type", "text"}, to: "#image-to-text-api-key-input")
                  |> JS.add_class("hidden", to: "#image-to-text-api-key-show")
                  |> JS.remove_class("hidden", to: "#image-to-text-api-key-hide")
                }
                class="absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"
                  /><path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                  />
                </svg>
              </button>
              <button
                type="button"
                id="image-to-text-api-key-hide"
                phx-click={
                  JS.set_attribute({"type", "password"}, to: "#image-to-text-api-key-input")
                  |> JS.remove_class("hidden", to: "#image-to-text-api-key-show")
                  |> JS.add_class("hidden", to: "#image-to-text-api-key-hide")
                }
                class="hidden absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"
                  />
                </svg>
              </button>
            </div>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Image to Text Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Ingestion Panel ───────────────────────────────────────────────────

  attr :form, :any, required: true

  def ingestion_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Ingestion</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Document processing, chunking, and retrieval tuning.
        </p>
      </div>
      <div class="px-8 py-6">
        <.form
          id="ingestion-config-form"
          for={@form}
          phx-submit="save_ingestion"
          phx-change="validate_ingestion"
          class="space-y-5"
        >
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Base Path
            </label>
            <input
              type="text"
              name="ingestion_config[base_path]"
              value={@form[:base_path].value}
              phx-debounce="400"
              placeholder="/zaq/volumes/documents"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
            />
            <p
              :for={{msg, _opts} <- @form[:base_path].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {msg}
            </p>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Max Context Window (tokens)
              </label>
              <input
                type="number"
                min="1"
                name="ingestion_config[max_context_window]"
                value={@form[:max_context_window].value}
                phx-debounce="400"
                placeholder="5000"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:max_context_window].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Distance Threshold
              </label>
              <input
                type="number"
                min="0.01"
                step="0.01"
                name="ingestion_config[distance_threshold]"
                value={@form[:distance_threshold].value}
                phx-debounce="400"
                placeholder="1.2"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:distance_threshold].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Hybrid Search Limit
              </label>
              <input
                type="number"
                min="1"
                name="ingestion_config[hybrid_search_limit]"
                value={@form[:hybrid_search_limit].value}
                phx-debounce="400"
                placeholder="20"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:hybrid_search_limit].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Min Tokens
              </label>
              <input
                type="number"
                min="1"
                name="ingestion_config[chunk_min_tokens]"
                value={@form[:chunk_min_tokens].value}
                phx-debounce="400"
                placeholder="400"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:chunk_min_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Max Tokens
              </label>
              <input
                type="number"
                min="1"
                name="ingestion_config[chunk_max_tokens]"
                value={@form[:chunk_max_tokens].value}
                phx-debounce="400"
                placeholder="900"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, _opts} <- @form[:chunk_max_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {msg}
              </p>
            </div>
          </div>
          <div class="bg-[#fafafa] rounded-xl border border-black/5 px-4 py-3">
            <p class="font-mono text-[0.72rem] text-black/50 leading-relaxed">
              Changes take effect immediately for new ingestion jobs. Multi-volume setup
              still requires the <span class="font-semibold text-black/70">INGESTION_VOLUMES</span>
              env var.
            </p>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class="font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Save Ingestion Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Searchable Select (shared) ─────────────────────────────────────────

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, default: []
  attr :placeholder, :string, default: "Search..."
  attr :empty_label, :string, default: "Select..."

  defp searchable_select(assigns) do
    ~H"""
    <div id={@id} phx-hook="SearchableSelect" class="relative">
      <input type="hidden" name={@name} value={@value} data-select-value />
      <button
        type="button"
        data-select-trigger
        class="w-full flex items-center justify-between font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
      >
        <span data-select-label>
          {Enum.find_value(@options, @empty_label, fn {label, val} ->
            if to_string(val) == to_string(@value || ""), do: label
          end)}
        </span>
        <svg
          class="w-4 h-4 shrink-0 text-black/30"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <div
        data-select-panel
        class="hidden absolute z-50 w-full bg-white border border-black/10 rounded-xl shadow-lg mt-1 overflow-hidden"
      >
        <div class="p-2 border-b border-black/[0.06]">
          <input
            type="text"
            data-select-search
            placeholder={@placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-9 px-3 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
          />
        </div>
        <ul data-select-list class="max-h-52 overflow-y-auto py-1">
          <li
            :for={{label, value} <- @options}
            data-select-option={label}
            data-select-value={value}
            class="font-mono text-[0.82rem] text-black px-4 py-2 cursor-pointer hover:bg-[#03b6d4]/10 transition-colors"
          >
            {label}
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
