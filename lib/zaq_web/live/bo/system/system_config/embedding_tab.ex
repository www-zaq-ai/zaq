defmodule ZaqWeb.Live.BO.System.SystemConfig.EmbeddingTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  import ZaqWeb.Components.SearchableSelect

  # ── Embedding Panel ───────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true
  attr :locked, :boolean, default: false
  attr :unlock_modal, :boolean, default: false
  attr :model_changed, :boolean, default: false
  attr :save_confirm_modal, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <%!-- Unlock model — informational note --%>
    <div
      :if={@unlock_modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.08] w-full max-w-md mx-4 p-6">
        <h3 class="font-mono text-[0.95rem] font-bold text-black mb-2">Unlock Model Selection</h3>
        <p class="font-mono text-[0.8rem] text-black/60 leading-relaxed mb-5">
          You are about to unlock model selection. If you pick a different model, saving will permanently delete all existing embeddings and require full re-ingestion.
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_unlock_embedding"
            class="font-mono text-[0.82rem] px-5 py-2.5 rounded-xl border border-black/10 text-black/60 hover:bg-black/[0.04] transition-all"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_unlock_embedding"
            class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
          >
            Unlock
          </button>
        </div>
      </div>
    </div>

    <%!-- Destructive save confirmation modal --%>
    <div
      :if={@save_confirm_modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.08] w-full max-w-md mx-4 p-6">
        <h3 class="font-mono text-[0.95rem] font-bold text-black mb-2">Delete All Embeddings?</h3>
        <p class="font-mono text-[0.8rem] text-black/60 leading-relaxed mb-5">
          All existing embeddings will be permanently deleted and full re-ingestion will be required. This cannot be undone.
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_save_embedding"
            class="font-mono text-[0.82rem] px-5 py-2.5 rounded-xl border border-black/10 text-black/60 hover:bg-black/[0.04] transition-all"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_save_embedding"
            class="font-mono text-[0.82rem] font-bold px-5 py-2.5 rounded-xl bg-red-500 text-white hover:bg-red-600 transition-all"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>

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
          <div class="grid grid-cols-2 gap-4 items-start">
            <div>
              <div class="h-7 flex items-center mb-2">
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
                  AI Credential
                </label>
              </div>
              <.searchable_select
                id="embedding-credential-select"
                name="embedding_config[credential_id]"
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
              <div class="h-7 flex items-center justify-between mb-2">
                <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
                  Model
                </label>
                <div :if={@locked} class="flex items-center gap-2">
                  <span class="flex items-center gap-1 font-mono text-[0.68rem] font-semibold text-emerald-600 bg-emerald-50 border border-emerald-200 px-2 py-1 rounded-md">
                    <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                      />
                    </svg>
                    Locked
                  </span>
                  <button
                    type="button"
                    phx-click="unlock_embedding"
                    class="font-mono text-[0.68rem] font-semibold px-2 py-1 rounded-md border border-amber-300 text-amber-600 bg-amber-50 hover:bg-amber-100 transition-all"
                  >
                    Unlock
                  </button>
                </div>
              </div>
              <div class={[@locked && "opacity-50 pointer-events-none"]}>
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
                  disabled={@locked}
                  class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
                />
              </div>
              <p
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
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
              disabled={@locked}
              class={[
                "w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 placeholder:text-black/25 transition-all",
                if(@locked,
                  do: "bg-black/[0.03] text-black/40 cursor-not-allowed",
                  else:
                    "bg-[#fafafa] focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4]"
                )
              ]}
            />
            <p
              :for={{msg, opts} <- @form[:dimension].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
            <p
              :if={not @locked and @form[:dimension].value not in [nil, ""]}
              class="font-mono text-[0.72rem] text-amber-600 mt-1.5"
            >
              Changing the model or dimension will permanently delete all chunks and require re-ingestion.
            </p>
          </div>
          <div class="grid grid-cols-2 gap-4 border-t border-black/[0.06] pt-4">
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Min Tokens
              </label>
              <input
                type="number"
                min="1"
                name="embedding_config[chunk_min_tokens]"
                value={@form[:chunk_min_tokens].value}
                phx-debounce="400"
                placeholder="400"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:chunk_min_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
            <div>
              <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
                Chunk Max Tokens
              </label>
              <input
                type="number"
                min="1"
                name="embedding_config[chunk_max_tokens]"
                value={@form[:chunk_max_tokens].value}
                phx-debounce="400"
                placeholder="900"
                class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
              />
              <p
                :for={{msg, opts} <- @form[:chunk_max_tokens].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
            </div>
          </div>
          <div class="pt-2">
            <button
              type="submit"
              class={[
                "font-mono text-[0.82rem] font-bold px-6 py-3 rounded-xl text-white shadow-sm transition-all",
                if(@model_changed,
                  do: "bg-red-500 hover:bg-red-600 shadow-red-500/20",
                  else: "bg-[#03b6d4] hover:bg-[#029ab3] shadow-[#03b6d4]/20"
                )
              ]}
            >
              Save Embedding Settings
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
