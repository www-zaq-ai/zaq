defmodule ZaqWeb.Components.DesignSystem.ChannelPriorityList do
  @moduledoc """
  Parent-controlled contact-priority list: provider identity, rank and accessible moves.
  Emits move_channel with id/action or id/target; never owns or persists ordering.
  Desktop dragging progressively enhances the always-available move buttons.
  ChannelIcons logos are reused as decorative branding beside explicit text labels.
  """
  use Phoenix.Component

  alias ZaqWeb.Components.ChannelIcons
  alias ZaqWeb.Components.DesignSystem.Button

  attr :id, :string, required: true
  attr :channels, :list, required: true
  attr :editing, :boolean, default: false

  def channel_priority_list(assigns) do
    ~H"""
    <ol
      id={@id}
      class="zaq-layout-stack"
      phx-hook=".PriorityDrag"
      data-editing={to_string(@editing)}
      aria-label="Contact priority"
    >
      <li
        :for={{channel, index} <- Enum.with_index(@channels)}
        id={"#{@id}-#{channel.id}"}
        data-channel-id={channel.id}
        tabindex="-1"
        class="zaq-card-default zaq-layout-stack-tight min-w-0"
      >
        <div class="zaq-layout-inline min-w-0">
          <span
            :if={@editing}
            draggable="true"
            data-drag-handle
            class="cursor-grab shrink-0"
            aria-hidden="true"
            title="Drag to change priority, or use the move buttons"
          >
            <span class="hero-bars-3 zaq-icon-sm" />
          </span>
          <span class="zaq-text-h3 shrink-0" aria-label={"Priority #{index + 1}"}>{index + 1}</span>
          <span aria-hidden="true" class="shrink-0">
            <ChannelIcons.icon provider={channel.provider} class="zaq-icon-md" />
          </span>
          <h3 class="zaq-text-h3 min-w-0 break-words">{channel.platform}</h3>
        </div>
        <p class="zaq-text-body break-all">{channel.identifier}</p>
        <div :if={@editing} class="zaq-layout-inline flex-wrap">
          <Button.button
            id={"#{@id}-#{channel.id}-up"}
            variant={:ghost}
            icon="hero-arrow-up"
            phx-click="move_channel"
            phx-value-id={channel.id}
            phx-value-action="up"
            disabled={index == 0}
            aria-label={"Move up #{channel.platform}, #{channel.identifier}"}
          >Move up</Button.button>
          <Button.button
            id={"#{@id}-#{channel.id}-down"}
            variant={:ghost}
            icon="hero-arrow-down"
            phx-click="move_channel"
            phx-value-id={channel.id}
            phx-value-action="down"
            disabled={index == length(@channels) - 1}
            aria-label={"Move down #{channel.platform}, #{channel.identifier}"}
          >Move down</Button.button>
        </div>
      </li>
    </ol>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PriorityDrag">
      export default {
        mounted() {
          this.onStart = event => {
            const handle = event.target.closest('[data-drag-handle]');
            if (!handle || this.el.dataset.editing !== 'true') return;
            this.dragged = handle.closest('[data-channel-id]').dataset.channelId;
            event.dataTransfer.setData('text/plain', this.dragged);
            event.dataTransfer.effectAllowed = 'move';
          };
          this.onOver = event => {
            if (this.dragged && event.target.closest('[data-channel-id]')) {
              event.preventDefault();
              event.dataTransfer.dropEffect = 'move';
            }
          };
          this.onDrop = event => {
            const row = event.target.closest('[data-channel-id]');
            if (!this.dragged || !row || this.el.dataset.editing !== 'true') return;
            event.preventDefault();
            const id = this.dragged;
            this.dragged = null;
            this.pushEvent('move_channel', {id, target: row.dataset.channelId});
          };
          this.onEnd = () => { this.dragged = null; };
          this.el.addEventListener('dragstart', this.onStart);
          this.el.addEventListener('dragover', this.onOver);
          this.el.addEventListener('drop', this.onDrop);
          this.el.addEventListener('dragend', this.onEnd);
        },
        destroyed() {
          this.el.removeEventListener('dragstart', this.onStart);
          this.el.removeEventListener('dragover', this.onOver);
          this.el.removeEventListener('drop', this.onDrop);
          this.el.removeEventListener('dragend', this.onEnd);
        }
      }
    </script>
    """
  end
end
