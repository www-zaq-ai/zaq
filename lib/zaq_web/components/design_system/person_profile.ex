defmodule ZaqWeb.Components.DesignSystem.PersonProfile do
  @moduledoc """
  Presentational self-service profile shared by live and review surfaces. Parents
  supply display-ready data, drafts, errors and permissions, and own every event.
  This component neither authenticates nor persists, and knows no fixture scenarios.
  """
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.{Button, ChannelPriorityList, EmptyState, Input, Table}

  attr :profile, :map, required: true
  attr :mode, :atom, required: true
  attr :name_form, :any, required: true
  attr :name_errors, :list, default: []
  attr :draft_channels, :list, required: true
  attr :announcement, :string, default: ""
  attr :form_id, :string, default: "self-profile-form"
  attr :save_name_event, :string, default: "save_profile"

  def person_profile(assigns) do
    ~H"""
    <div
      id="person-profile-content"
      phx-hook=".ProfileFocus"
      class="grid grid-cols-1 lg:grid-cols-2 zaq-layout-section-gap items-start"
    >
      <div class="zaq-layout-stack min-w-0">
        <section class="zaq-card-default zaq-layout-stack" aria-labelledby="information-heading">
          <h2 id="information-heading" class="zaq-text-h2">Basic information</h2>
          <div :if={@mode != :name} class="zaq-layout-inline justify-between items-start flex-wrap">
            <dl class="min-w-0 flex-1">
              <dt class="zaq-text-h4">Full name</dt>
              <dd class="zaq-text-body break-words">{display(@profile.person.full_name)}</dd>
            </dl>
            <Button.button
              :if={@profile.editable}
              id="edit-name"
              variant={:ghost}
              icon="hero-pencil-square"
              phx-click="edit_name"
              disabled={@mode != :read}
            >Edit name</Button.button>
          </div>
          <.form
            :if={@mode == :name}
            for={@name_form}
            id={@form_id}
            phx-submit={@save_name_event}
            phx-change="validate_name"
            class="zaq-layout-stack"
          >
            <Input.input
              id="profile-name"
              name="profile[full_name]"
              value={@name_form[:full_name].value}
              label="Full name"
              autocomplete="name"
              errors={@name_errors}
            />
            <div class="zaq-layout-inline flex-wrap">
              <Button.button type="submit" phx-disable-with="Saving…">Save name</Button.button>
              <Button.button variant={:secondary} phx-click="cancel">Cancel</Button.button>
            </div>
          </.form>
          <dl class="grid grid-cols-1 sm:grid-cols-2 zaq-layout-grid-gap">
            <div
              :for={
                {field, label} <- [email: "Email", phone: "Phone", role: "Role", status: "Status"]
              }
              class="min-w-0"
            >
              <dt class="zaq-text-h4">{label}</dt>
              <dd :if={field != :status} class="zaq-text-body break-all">
                {display(Map.fetch!(@profile.person, field))}
              </dd>
              <dd :if={field == :status}>
                <Table.table_badge status={Map.fetch!(@profile.person, field)} />
              </dd>
            </div>
          </dl>
        </section>
        <section class="zaq-card-default zaq-layout-stack" aria-labelledby="teams-heading">
          <h2 id="teams-heading" class="zaq-text-h2">Teams ({length(@profile.teams)})</h2>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            Your current team memberships.
          </p>
          <EmptyState.empty_state
            :if={@profile.teams == []}
            title="No teams"
            hint="You are not currently a member of a team."
          />
          <ul :if={@profile.teams != []} class="zaq-layout-stack-tight">
            <li :for={team <- @profile.teams} class="zaq-layout-inline min-w-0">
              <span class="hero-user-group zaq-icon-sm shrink-0" aria-hidden="true" />
              <span class="zaq-text-body break-words min-w-0">{team}</span>
            </li>
          </ul>
        </section>
      </div>
      <section class="zaq-card-default zaq-layout-stack min-w-0" aria-labelledby="channels-heading">
        <div class="zaq-layout-stack-tight">
          <h2 id="channels-heading" class="zaq-text-h2">Contact channels</h2>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            We try your channels in the order shown.
          </p>
        </div>
        <EmptyState.empty_state
          :if={@profile.channels == []}
          title="No channels"
          hint="There are no contact channels linked to your profile."
        />
        <p :if={@mode == :order} id="order-instructions" tabindex="-1" class="zaq-text-body-sm">
          Drag a handle or use Move up and Move down. Changes apply only when you save.
        </p>
        <ChannelPriorityList.channel_priority_list
          :if={@profile.channels != []}
          id="channel-priority"
          channels={@draft_channels}
          editing={@mode == :order}
        />
        <p
          id="reorder-announcement"
          class="zaq-text-body-sm"
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          {@announcement}
        </p>
        <p :if={@mode == :order && @draft_channels != @profile.channels} class="zaq-text-body-sm">
          Order changed. Save to apply your preferences.
        </p>
        <div :if={@mode == :order} class="zaq-layout-inline flex-wrap">
          <Button.button
            phx-click="save_order"
            phx-disable-with="Saving…"
            disabled={@draft_channels == @profile.channels}
          >Save order</Button.button>
          <Button.button variant={:secondary} phx-click="cancel">Cancel</Button.button>
        </div>
        <Button.button
          :if={@profile.editable && length(@profile.channels) > 1 && @mode != :order}
          id="edit-order"
          variant={:secondary}
          icon="hero-arrows-up-down"
          phx-click="edit_order"
          disabled={@mode != :read}
        >Change order</Button.button>
      </section>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProfileFocus">
      export default {
        mounted() {
          this.handleEvent('profile-focus', ({id}) => {
            requestAnimationFrame(() => {
              const target = document.getElementById(id);
              if (!target || !this.el.contains(target)) return;
              // Preserve the keyboard's move button when still usable after a move.
              if (target.contains(document.activeElement) && !document.activeElement.disabled) return;
              target.focus();
            });
          });
        }
      }
    </script>
    """
  end

  defp display(value) when value in [nil, ""], do: "Not provided"
  defp display(value), do: value
end
