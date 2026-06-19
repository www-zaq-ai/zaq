defmodule Storybook.Components.DesignSystem.ModalShare do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ModalShare

  def description,
    do: "Share modal: public toggle, permissions, pending grants, searchable target picker."

  def render(assigns) do
    perm = %{
      id: "1",
      person: %{full_name: "Alex Example", email: "alex@example.com"},
      team: nil,
      access_rights: ["read", "write"]
    }

    pending = [%{name: "Team Alpha", access_rights: ["read"]}]

    assigns =
      assigns
      |> assign(:modal_name, "strategy-2026.pdf")
      |> assign(:modal_error, nil)
      |> assign(:share_modal_is_folder, false)
      |> assign(:share_modal_is_public, false)
      |> assign(:share_modal_original_is_public, false)
      |> assign(:share_modal_permissions, [perm])
      |> assign(:share_modal_targets_options, [
        {"Alex Example", "person:1"},
        {"Team Alpha", "team:1"}
      ])
      |> assign(:share_modal_pending, pending)

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.modal_share
        modal_name={@modal_name}
        modal_error={@modal_error}
        share_modal_is_folder={@share_modal_is_folder}
        share_modal_is_public={@share_modal_is_public}
        share_modal_original_is_public={@share_modal_original_is_public}
        share_modal_permissions={@share_modal_permissions}
        share_modal_targets_options={@share_modal_targets_options}
        share_modal_pending={@share_modal_pending}
      />
    </div>
    """
  end
end
