defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  import ZaqWeb.Components.SearchableSelect

  # ── LLM Panel ─────────────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :capabilities, :map, required: true

  def panel(assigns) do
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
          novalidate
        >
          <input type="hidden" name="llm_config[path]" value={@form[:path].value} />
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                AI Credential
              </label>
              <.searchable_select
                id="llm-credential-select"
                name="llm_config[credential_id]"
                value={to_string(@form[:credential_id].value || "")}
                options={@credential_options}
                placeholder="Search credentials..."
                empty_label="Select a credential..."
              />
              <p
                :for={{msg, opts} <- @form[:credential_id].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
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
                required
                phx-debounce="400"
                placeholder="llama-3.3-70b-instruct"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
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
                :for={{msg, opts} <- @form[:temperature].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Top-P
              </label>
              <input
                type="number"
                min="0"
                max="1"
                step="0.05"
                name="llm_config[top_p]"
                value={@form[:top_p].value}
                phx-debounce="400"
                placeholder="0.9"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:top_p].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Max Context Window (tokens)
              </label>
              <input
                type="number"
                min="1"
                name="llm_config[max_context_window]"
                value={@form[:max_context_window].value}
                phx-debounce="400"
                placeholder="5000"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:max_context_window].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
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
                name="llm_config[distance_threshold]"
                value={@form[:distance_threshold].value}
                phx-debounce="400"
                placeholder="1.2"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:distance_threshold].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <details
            id="llm-fusion-advanced"
            phx-hook="DetailsKeepOpen"
            class="border border-black/[0.08] rounded-xl overflow-hidden"
          >
            <summary class="cursor-pointer select-none px-4 py-3 font-mono text-[0.75rem] font-semibold text-black/50 uppercase tracking-wider hover:bg-black/[0.02] transition-colors list-none flex items-center gap-2">
              <svg
                class="w-3.5 h-3.5 transition-transform details-open:rotate-90"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
                  clip-rule="evenodd"
                />
              </svg>
              Advanced — Hybrid Search Fusion Weights
            </summary>
            <div class="px-4 pb-4 pt-3 bg-black/[0.01] border-t border-black/[0.06] grid grid-cols-2 gap-4">
              <div>
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                  BM25 Weight
                </label>
                <input
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  name="llm_config[fusion_bm25_weight]"
                  value={@form[:fusion_bm25_weight].value}
                  phx-debounce="400"
                  placeholder="0.5"
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
                <p
                  :for={{msg, opts} <- @form[:fusion_bm25_weight].errors}
                  class="font-mono text-[0.72rem] text-red-500 mt-1.5"
                >
                  {translate_error({msg, opts})}
                </p>
              </div>
              <div>
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                  Vector Weight
                </label>
                <input
                  type="number"
                  min="0"
                  max="1"
                  step="0.01"
                  name="llm_config[fusion_vector_weight]"
                  value={@form[:fusion_vector_weight].value}
                  phx-debounce="400"
                  placeholder="0.5"
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
                <p
                  :for={{msg, opts} <- @form[:fusion_vector_weight].errors}
                  class="font-mono text-[0.72rem] text-red-500 mt-1.5"
                >
                  {translate_error({msg, opts})}
                </p>
              </div>
            </div>
          </details>
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
end
