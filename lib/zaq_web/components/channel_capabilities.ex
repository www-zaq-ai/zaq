defmodule ZaqWeb.Components.ChannelCapabilities do
  @moduledoc """
  Reusable component to unformly display Channel's capabilities
  """
  use ZaqWeb, :html

  attr :modal_open?, :boolean, default: false
  attr :snapshot, :map, default: %{}
  attr :title, :string, required: true
  attr :open_event, :string, default: "open_capabilities"
  attr :close_event, :string, default: "close_capabilities"

  def icon_with_modal(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@open_event}
      data-testid="channel-capabilities-trigger"
      class="w-6 h-6 rounded-md border border-black/10 grid place-items-center text-black/35 hover:text-[#03b6d4] hover:border-[#03b6d4]/30 transition-all"
      title="Show capabilities"
    >
      <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path d="M12 16v.01" />
        <path d="M12 8a2.5 2.5 0 0 1 2.5 2.5c0 1.5-1.5 2-2.5 2.75" />
        <circle cx="12" cy="12" r="9" />
      </svg>
    </button>

    <ZaqWeb.Components.BOModal.form_dialog
      :if={@modal_open?}
      id="capabilities-modal"
      cancel_event={@close_event}
      title="Capabilities"
      max_width_class="max-w-lg"
    >
      <div class="space-y-3">
        <p class="font-mono text-[0.75rem] text-black/65">{@title}</p>
        <ul class="space-y-1 max-h-[55vh] overflow-auto pr-1">
          <li
            :for={capability <- capability_items(@snapshot)}
            class={[
              "font-mono text-[0.74rem]",
              if(capability.supported?, do: "text-emerald-700", else: "text-black/40")
            ]}
          >
            {capability.label}
          </li>
        </ul>
        <div class="flex justify-end pt-2">
          <button
            type="button"
            phx-click={@close_event}
            class="font-mono text-[0.75rem] px-4 py-2 rounded-lg border border-black/10 text-black/50 hover:text-black"
          >
            Close
          </button>
        </div>
      </div>
    </ZaqWeb.Components.BOModal.form_dialog>
    """
  end

  defp capability_items(snapshot) do
    labels = Map.get(snapshot, :labels, %{})
    required = Map.get(snapshot, :required, [])
    resolved = Map.get(snapshot, :resolved, %{})

    required
    |> Enum.map(fn capability ->
      value = Map.get(resolved, capability) || Map.get(resolved, to_string(capability))
      label = Map.get(labels, capability, capability) |> to_string()

      display_label =
        case {capability, value} do
          {:mode, mode} when is_binary(mode) and mode != "" -> "#{label}: #{mode}"
          {"mode", mode} when is_binary(mode) and mode != "" -> "#{label}: #{mode}"
          _ -> label
        end

      %{
        label: display_label,
        supported?: not is_nil(value) and value != false
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.label))
  end
end
