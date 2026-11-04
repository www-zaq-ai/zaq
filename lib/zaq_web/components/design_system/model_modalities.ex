defmodule ZaqWeb.Components.DesignSystem.ModelModalities do
  @moduledoc """
  Compact catalog model input → output modalities, shared by agent forms and lists.

  Metadata is supplied by the caller; this component never discovers models. Missing
  directions are unknown, not unsupported. Tooltips identify direction and modality
  on hover, focus or tap. Neither triggers nor tooltip content activate an enclosing
  selectable row. Tooltips follow the visible portion of their trigger and close
  when it leaves the viewport or an ancestor's horizontal/vertical clipping bounds.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  @modality_icons [
    text: {"Text", "hero-bars-3-bottom-left"},
    image: {"Image", "hero-photo"},
    audio: {"Audio", "hero-musical-note"},
    video: {"Video", "hero-film"},
    code: {"Code", "hero-code-bracket"},
    document: {"Document", "hero-document-text"},
    embedding: {"Embedding", "hero-squares-2x2"},
    embeddings: {"Embeddings", "hero-squares-plus"},
    decisions: {"Decisions", "hero-arrows-right-left"},
    file: {"File", "hero-document"},
    rerank: {"Rerank", "hero-bars-arrow-down"},
    speech: {"Speech", "hero-microphone"},
    transcription: {"Transcription", "hero-chat-bubble-bottom-center-text"},
    pdf: {"PDF", "hero-document-magnifying-glass"}
  ]

  attr :id, :string, required: true
  attr :modalities, :map, default: nil
  attr :selected, :boolean, default: true

  def model_modalities(assigns) do
    assigns =
      assign(assigns, :directions, [
        {"Input", entries(assigns.modalities, :input)},
        {"Output", entries(assigns.modalities, :output)}
      ])

    ~H"""
    <span
      id={@id}
      class="zaq-model-modalities"
      phx-hook=".ModalityTooltips"
      role="group"
      aria-label="Model capabilities (catalog)"
    >
      <span :if={!@selected} class="zaq-text-body-sm">Select a model to view modalities</span>
      <span
        :for={{direction, entries} <- @directions}
        :if={@selected}
        class="zaq-model-modalities-group"
      >
        <.icon
          :if={direction == "Output"}
          name="hero-arrow-right"
          class="zaq-icon-sm zaq-model-modalities-arrow"
        />
        <span :for={{{label, icon}, index} <- Enum.with_index(entries)} class="zaq-model-modality">
          <button
            type="button"
            class="zaq-model-modality-trigger"
            aria-label={"#{direction}: #{label}"}
            aria-describedby={"#{@id}-#{direction}-#{index}-tooltip"}
          >
            <.icon name={icon} class="zaq-icon-sm" />
          </button>
          <span
            id={"#{@id}-#{direction}-#{index}-tooltip"}
            role="tooltip"
            popover="manual"
            class="zaq-model-modality-tooltip zaq-text-body-sm"
          >
            {direction}: {label}
          </span>
        </span>
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ModalityTooltips">
      export default {
        mounted() {
          this.hide = () => {
            if (this.tooltip?.isConnected) this.tooltip.hidePopover();
            this.tooltip = null;
            this.trigger = null;
            this.touchOpen = false;
          };
          this.visibleTriggerRect = () => {
            const rect = this.trigger.getBoundingClientRect();
            const visible = {
              left: Math.max(0, rect.left),
              right: Math.min(document.documentElement.clientWidth, rect.right),
              top: Math.max(0, rect.top),
              bottom: Math.min(window.innerHeight, rect.bottom)
            };
            for (let parent = this.trigger.parentElement; parent; parent = parent.parentElement) {
              const style = getComputedStyle(parent);
              const clipsX = /^(auto|scroll|hidden|clip)$/.test(style.overflowX);
              const clipsY = /^(auto|scroll|hidden|clip)$/.test(style.overflowY);
              if (!clipsX && !clipsY) continue;
              const bounds = parent.getBoundingClientRect();
              const left = bounds.left + parent.clientLeft;
              const top = bounds.top + parent.clientTop;
              if (clipsX) {
                visible.left = Math.max(visible.left, left);
                visible.right = Math.min(visible.right, left + parent.clientWidth);
              }
              if (clipsY) {
                visible.top = Math.max(visible.top, top);
                visible.bottom = Math.min(visible.bottom, top + parent.clientHeight);
              }
            }
            return visible.right > visible.left && visible.bottom > visible.top ? visible : null;
          };
          this.position = () => {
            if (!this.tooltip || !this.trigger?.isConnected) return;
            const rect = this.visibleTriggerRect();
            if (!rect) {
              this.hide();
              return;
            }
            const box = this.tooltip.getBoundingClientRect();
            const inset = 8;
            const left = Math.max(inset, Math.min(rect.left, document.documentElement.clientWidth - box.width - inset));
            const top = rect.top >= box.height + inset ? rect.top - box.height - inset : rect.bottom + inset;
            this.tooltip.style.left = `${left}px`;
            this.tooltip.style.top = `${top}px`;
          };
          this.show = trigger => {
            this.hide();
            this.trigger = trigger;
            this.tooltip = document.getElementById(trigger.getAttribute('aria-describedby'));
            this.tooltip.showPopover();
            this.position();
          };
          this.onEnter = event => {
            const trigger = event.target.closest('.zaq-model-modality-trigger');
            if (trigger && !trigger.contains(event.relatedTarget)) this.show(trigger);
          };
          this.onLeave = event => {
            if (!this.el.contains(event.relatedTarget)) this.hide();
          };
          this.onPointerLeave = event => {
            // WebKit can emit a compatibility mouse leave when a tapped trigger
            // moves during scrolling. Its tooltip follows clipping, not hover.
            if (event.pointerType !== 'touch' && !this.touchOpen && !this.el.contains(event.relatedTarget)) this.hide();
          };
          this.onPointerDown = event => {
            if (event.target.closest('.zaq-model-modality-trigger')) this.lastPointerType = event.pointerType;
            if (!event.target.closest('.zaq-model-modality-tooltip')) return;
            // Keep focus on the trigger: blur would remove the top-layer target
            // before click dispatch, retargeting the click to the selectable row.
            event.preventDefault();
            event.stopPropagation();
          };
          this.onClick = event => {
            if (event.target.closest('.zaq-model-modality-tooltip')) {
              event.stopPropagation();
              return;
            }
            const trigger = event.target.closest('.zaq-model-modality-trigger');
            if (!trigger) return;
            event.stopPropagation();
            this.show(trigger);
            this.touchOpen = event.detail > 0 && this.lastPointerType === 'touch';
          };
          this.onOutside = event => {
            if (!this.el.contains(event.target)) this.hide();
          };
          this.onKey = event => {
            if (event.key === 'Escape' && this.tooltip) {
              event.stopPropagation();
              this.hide();
            }
          };
          this.el.addEventListener('pointerover', this.onEnter);
          this.el.addEventListener('focusin', this.onEnter);
          this.el.addEventListener('pointerleave', this.onPointerLeave);
          this.el.addEventListener('focusout', this.onLeave);
          this.el.addEventListener('pointerdown', this.onPointerDown);
          this.el.addEventListener('click', this.onClick);
          document.addEventListener('keydown', this.onKey);
          document.addEventListener('click', this.onOutside);
          document.addEventListener('scroll', this.position, true);
          window.addEventListener('resize', this.hide);
        },
        beforeUpdate() { this.hide(); },
        destroyed() {
          this.hide();
          this.el.removeEventListener('pointerdown', this.onPointerDown);
          document.removeEventListener('keydown', this.onKey);
          document.removeEventListener('click', this.onOutside);
          document.removeEventListener('scroll', this.position, true);
          window.removeEventListener('resize', this.hide);
        }
      }
    </script>
    """
  end

  defp entries(modalities, direction) do
    case modalities && Map.get(modalities, direction) do
      values when is_list(values) and values != [] ->
        values
        |> Enum.uniq()
        |> Enum.sort_by(&{Enum.find_index(@modality_icons, fn {key, _} -> key == &1 end), &1})
        |> Enum.map(&modality_icon/1)

      _ ->
        [{"Unknown", "hero-question-mark-circle"}]
    end
  end

  defp modality_icon(modality) do
    Keyword.get_lazy(@modality_icons, modality, fn ->
      {modality |> to_string() |> String.replace("_", " ") |> String.capitalize(),
       "hero-question-mark-circle"}
    end)
  end
end
