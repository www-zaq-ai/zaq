defmodule ZaqWeb.Live.BO.System.SystemConfig.TelemetryTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html

  # ── Telemetry Panel ────────────────────────────────────────────────────

  attr :form, :any, required: true

  def panel(assigns) do
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
                :for={{msg, opts} <- @form[:request_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
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
                :for={{msg, opts} <- @form[:repo_query_duration_threshold_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
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
                :for={{msg, opts} <- @form[:no_answer_alert_threshold_percent].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
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
                :for={{msg, opts} <- @form[:conversation_response_sla_ms].errors}
                class="font-mono text-[0.72rem] text-red-500 mt-1.5"
              >
                {translate_error({msg, opts})}
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
end
