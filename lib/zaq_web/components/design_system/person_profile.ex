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
        <section
          class="zaq-card-default zaq-card-hover zaq-border-default zaq-layout-stack"
          aria-labelledby="information-heading"
        >
          <div class="zaq-layout-inline items-center flex-wrap min-w-0">
            <h2 id="information-heading" class="zaq-text-h2 break-words min-w-0">
              {profile_title(@profile.person.full_name)}
            </h2>
            <Button.button
              :if={@profile.editable && @mode != :name}
              id="edit-name"
              variant={:ghost}
              icon="hero-pencil-square"
              icon_only
              title="Edit name"
              aria-label="Edit name"
              phx-click="edit_name"
              disabled={@mode != :read}
            />
          </div>
          <.form
            :if={@mode == :name}
            for={@name_form}
            id={@form_id}
            phx-submit={@save_name_event}
            phx-change="validate_name"
            class="zaq-layout-inline items-start flex-wrap"
          >
            <div class="min-w-0 flex-1">
              <Input.input
                id="profile-name"
                name="profile[full_name]"
                value={@name_form[:full_name].value}
                label="Full name"
                autocomplete="name"
                errors={@name_errors}
              />
            </div>
            <div class="zaq-layout-inline shrink-0 mt-5">
              <Button.button type="submit" phx-disable-with="Saving…">Save name</Button.button>
              <Button.button variant={:secondary} phx-click="cancel">Cancel</Button.button>
            </div>
          </.form>
          <dl class="grid grid-cols-1 sm:grid-cols-2 zaq-layout-grid-gap">
            <div class="min-w-0">
              <dt class="sr-only">Email</dt>
              <dd class="zaq-layout-inline min-w-0">
                <span class="hero-envelope zaq-icon-sm shrink-0" aria-hidden="true" />
                <span class="zaq-text-body break-all min-w-0">
                  {display(@profile.person.email)}
                </span>
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="sr-only">Phone</dt>
              <dd class="zaq-layout-inline min-w-0">
                <span class="hero-phone zaq-icon-sm shrink-0" aria-hidden="true" />
                <span class="zaq-text-body break-all min-w-0">
                  {display(@profile.person.phone)}
                </span>
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="zaq-text-h4">Role</dt>
              <dd class="zaq-text-body break-all">{display(@profile.person.role)}</dd>
            </div>
            <div class="min-w-0">
              <dt class="zaq-text-h4">Status</dt>
              <dd>
                <Table.table_badge status={@profile.person.status} />
              </dd>
            </div>
          </dl>
        </section>
        <section
          class="zaq-card-default zaq-card-hover zaq-border-default zaq-layout-stack"
          aria-labelledby="teams-heading"
        >
          <h2 id="teams-heading" class="zaq-text-h2">Teams ({length(@profile.teams)})</h2>
          <p
            :if={@profile.teams != []}
            class="zaq-text-body-sm"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            Your current team memberships.
          </p>
          <p
            :if={@profile.teams == []}
            class="zaq-text-body-sm"
            style="color: var(--zaq-text-color-body-tertiary)"
          >
            You’re not part of a team yet.
          </p>
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
            ZAQ sends notifications to your first contact channel. If delivery fails, ZAQ uses the next channel in this list.
          </p>
        </div>
        <EmptyState.empty_state
          :if={@profile.channels == []}
          title="No channels"
          hint="There are no contact channels linked to your profile."
        />
        <p :if={@mode == :order} id="order-instructions" tabindex="-1" class="zaq-text-body-sm">
          Move your preferred contact channel to the top. Drag a channel or use the arrow buttons, then save your preferences.
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
          Your contact priority has changed. Save to apply your preferences.
        </p>
        <div :if={@mode == :order} class="zaq-layout-inline flex-wrap">
          <Button.button
            phx-click="save_order"
            phx-disable-with="Saving…"
            disabled={@draft_channels == @profile.channels}
          >Save preferences</Button.button>
          <Button.button variant={:secondary} phx-click="cancel">Cancel</Button.button>
        </div>
        <Button.button
          :if={@profile.editable && length(@profile.channels) > 1 && @mode != :order}
          id="edit-order"
          variant={:secondary}
          icon="hero-arrows-up-down"
          phx-click="edit_order"
          disabled={@mode != :read}
        >Change contact priority</Button.button>
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

  defp profile_title(value) when value in [nil, ""], do: "Your profile"
  defp profile_title(value), do: value
end
