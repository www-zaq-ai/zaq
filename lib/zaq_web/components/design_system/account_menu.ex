defmodule ZaqWeb.Components.DesignSystem.AccountMenu do
  @moduledoc """
  Shared avatar/name account disclosure extracted from the BO header.
  Callers own identity, destinations and labels; IDs can preserve existing DOM contracts.
  Native disclosure semantics provide keyboard activation without JavaScript. The
  colocated hook adds header-wide mutual/outside dismissal and viewport positioning.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :display_name, :string, default: nil
  attr :profile_url, :string, required: true
  attr :logout_action, :string, required: true
  attr :trigger_id, :string, default: nil
  attr :panel_id, :string, default: nil
  attr :profile_id, :string, default: nil
  attr :logout_form_id, :string, default: nil
  attr :logout_button_id, :string, default: nil
  attr :profile_label, :string, default: "Profile"
  attr :logout_label, :string, default: "Logout"
  attr :name_class, :any, default: nil

  def account_menu(assigns) do
    name = String.trim(assigns.display_name || "")
    name = if name == "", do: "Profile", else: name
    assigns = assign(assigns, name: name, initial: name |> String.first() |> String.upcase())

    ~H"""
    <details id={@id} class="zaq-account-menu" phx-hook=".AccountDisclosure">
      <summary
        id={@trigger_id || "#{@id}-trigger"}
        class="zaq-btn zaq-btn-secondary zaq-header-menu-trigger zaq-layout-inline zaq-account-trigger"
        aria-label={"Account menu: #{@name}"}
        aria-controls={@panel_id || "#{@id}-panel"}
      >
        <span class="zaq-text-body-sm zaq-account-avatar" aria-hidden="true">{@initial}</span>
        <span class={["zaq-text-body-sm zaq-account-name", @name_class]}>{@name}</span>
      </summary>
      <div id={@panel_id || "#{@id}-panel"} class="zaq-account-panel">
        <a
          id={@profile_id || "#{@id}-profile"}
          href={@profile_url}
          class="zaq-text-body-sm zaq-dropdown-menu-item zaq-account-item"
        >
          {@profile_label}
        </a>
        <div class="zaq-account-divider" />
        <form id={@logout_form_id || "#{@id}-logout-form"} method="post" action={@logout_action}>
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <button
            id={@logout_button_id || "#{@id}-logout-button"}
            type="submit"
            class="zaq-text-body-sm zaq-dropdown-menu-item zaq-account-item zaq-account-logout"
          >
            {@logout_label}
          </button>
        </form>
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AccountDisclosure">
      export default {
        mounted() {
          this.header = this.el.closest('.zaq-page-header') || this.el;
          this.menus = () => new Set([this.el, ...this.header.querySelectorAll('details')]);
          this.closeOthers = current => this.menus().forEach(menu => {
            if (menu !== current) menu.open = false;
          });
          this.position = () => {
            if (!this.el.open) return;
            const panel = this.el.querySelector('.zaq-account-panel');
            const trigger = this.el.querySelector('summary').getBoundingClientRect();
            const inset = 8;
            const width = document.documentElement.clientWidth;
            const height = window.innerHeight;
            panel.style.left = `${Math.max(inset, Math.min(trigger.right - panel.offsetWidth, width - panel.offsetWidth - inset))}px`;
            const top = Math.max(inset, Math.min(trigger.bottom + inset, height - panel.offsetHeight - inset));
            panel.style.top = `${top}px`;
            panel.style.maxHeight = `${Math.max(0, height - top - inset)}px`;
          };
          this.onClick = event => {
            const summary = event.target.closest('summary');
            const current = summary?.parentElement;
            this.menus().forEach(menu => {
              if (!menu.contains(event.target) || (current && current !== menu)) menu.open = false;
            });
          };
          this.onToggle = event => {
            if (event.target.tagName !== 'DETAILS' || !event.target.open) return;
            this.closeOthers(event.target);
            this.position();
          };
          this.onKey = event => {
            if (event.key !== 'Escape') return;
            const open = Array.from(this.menus()).find(menu => menu.open);
            if (open) { open.open = false; open.querySelector('summary').focus(); }
          };
          this.onFocus = event => {
            this.menus().forEach(menu => {
              if (!menu.contains(event.target)) menu.open = false;
            });
          };
          document.addEventListener('click', this.onClick);
          document.addEventListener('keydown', this.onKey);
          document.addEventListener('focusin', this.onFocus);
          this.header.addEventListener('toggle', this.onToggle, true);
          window.addEventListener('resize', this.position);
          document.addEventListener('scroll', this.position, true);
        },
        updated() { this.position(); },
        destroyed() {
          document.removeEventListener('click', this.onClick);
          document.removeEventListener('keydown', this.onKey);
          document.removeEventListener('focusin', this.onFocus);
          this.header.removeEventListener('toggle', this.onToggle, true);
          window.removeEventListener('resize', this.position);
          document.removeEventListener('scroll', this.position, true);
        }
      }
    </script>
    """
  end
end
