defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  import ZaqWeb.Components.SearchableSelect

  # ── Image to Text Panel ───────────────────────────────────────────────

  attr :form, :any, required: true
  attr :credential_options, :list, required: true
  attr :model_options, :list, required: true

  def panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl">
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
                AI Credential
              </label>
              <.searchable_select
                id="image-to-text-credential-select"
                name="image_to_text_config[credential_id]"
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
                :for={{msg, opts} <- @form[:model].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
              </p>
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
end
