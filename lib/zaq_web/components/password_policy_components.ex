defmodule ZaqWeb.Components.PasswordPolicyComponents do
  @moduledoc """
  UI helpers for password policy feedback.

  Provides components that display password requirement status while users type.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :requirements, :list, required: true

  attr :id, :string,
    default: "password-requirements",
    doc: "Root element id for tests and anchors."

  attr :title, :string, default: "Password Requirements", doc: "Section heading copy."

  attr :class, :any,
    default: nil,
    doc: "Optional layout utilities merged onto the panel wrapper (not colors)."

  @doc "Renders the password requirements checklist with pass/fail state."
  def password_requirements(assigns) do
    ~H"""
    <div id={@id} class={["zaq-password-requirements", @class]}>
      <p class="zaq-field-label-uppercase">
        {@title}
      </p>
      <ul class="zaq-password-requirements__list">
        <li
          :for={requirement <- @requirements}
          id={"password-requirement-#{requirement.id}"}
          class={[
            "zaq-password-requirements__row zaq-text-body-sm",
            requirement.met? && "zaq-password-requirements__row--met",
            !requirement.met? && "zaq-password-requirements__row--unmet"
          ]}
        >
          <.icon
            name={if(requirement.met?, do: "hero-check-circle", else: "hero-x-circle")}
            class="zaq-icon-sm"
          />
          <span>{requirement.label}</span>
          <span class="sr-only">{if(requirement.met?, do: "Met", else: "Not met")}</span>
        </li>
      </ul>
    </div>
    """
  end
end
