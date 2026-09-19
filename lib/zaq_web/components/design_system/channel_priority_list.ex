defmodule ZaqWeb.Components.DesignSystem.ChannelPriorityList do
  @moduledoc """
  Parent-controlled contact-priority list: provider identity, rank and accessible moves.
  Emits move_channel with id/action or id/target; never owns or persists ordering.
  Desktop dragging progressively enhances the always-available move buttons.
  ChannelIcons logos are reused as decorative branding beside explicit text labels.
  """
  use Phoenix.Component

  alias ZaqWeb.Components.ChannelIcons
  alias ZaqWeb.Components.DesignSystem.{Button, Table}

  attr :id, :string, required: true
  attr :channels, :list, required: true
  attr :editing, :boolean, default: false

  def channel_priority_list(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".PriorityDrag"
      data-editing={to_string(@editing)}
    >
      <Table.table id={"#{@id}-table"}>
        <:head>
          <Table.table_head_row>
            <Table.table_cell element={:th} align={:center}>
              <Table.table_text label="Priority" tone={:tertiary} />
            </Table.table_cell>
            <Table.table_cell element={:th}>
              <Table.table_text label="Channel" tone={:tertiary} />
            </Table.table_cell>
            <Table.table_cell element={:th}>
              <Table.table_text label="Contact" tone={:tertiary} />
            </Table.table_cell>
            <Table.table_cell :if={@editing} element={:th} align={:right}>
              <span class="sr-only">Reorder actions</span>
            </Table.table_cell>
          </Table.table_head_row>
        </:head>
        <:body>
          <Table.table_row
            :for={{channel, index} <- Enum.with_index(@channels)}
            id={"#{@id}-#{channel.id}"}
            data-channel-id={channel.id}
            tabindex="-1"
          >
            <Table.table_cell align={:center} nowrap>
              <div class="zaq-layout-inline justify-center">
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
                <span class="zaq-text-body" aria-label={"Priority #{index + 1}"}>
                  {index + 1}
                </span>
              </div>
            </Table.table_cell>
            <Table.table_cell>
              <div class="zaq-layout-inline min-w-0">
                <span
                  aria-hidden="true"
                  class="w-6 h-6 rounded-md grid place-items-center shrink-0"
                  style="background: var(--zaq-surface-color-elevated)"
                >
                  <ChannelIcons.icon provider={channel.provider} class="w-3.5 h-3.5" />
                </span>
                <Table.table_text label={channel.platform} />
              </div>
            </Table.table_cell>
            <Table.table_cell>
              <Table.table_text
                label={channel.identifier}
                tone={:secondary}
                class="break-all"
              />
            </Table.table_cell>
            <Table.table_cell :if={@editing} align={:right} nowrap>
              <Table.table_actions>
                <Button.button
                  id={"#{@id}-#{channel.id}-up"}
                  variant={:ghost}
                  icon="hero-arrow-up"
                  icon_only
                  title="Move up"
                  phx-click="move_channel"
                  phx-value-id={channel.id}
                  phx-value-action="up"
                  disabled={index == 0}
                  aria-label={"Move up #{channel.platform}, #{channel.identifier}"}
                />
                <Button.button
                  id={"#{@id}-#{channel.id}-down"}
                  variant={:ghost}
                  icon="hero-arrow-down"
                  icon_only
                  title="Move down"
                  phx-click="move_channel"
                  phx-value-id={channel.id}
                  phx-value-action="down"
                  disabled={index == length(@channels) - 1}
                  aria-label={"Move down #{channel.platform}, #{channel.identifier}"}
                />
              </Table.table_actions>
            </Table.table_cell>
          </Table.table_row>
        </:body>
      </Table.table>
    </div>
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
