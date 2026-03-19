defmodule ZaqWeb.Components.PasswordPolicyComponents do
  @moduledoc false

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :requirements, :list, required: true

  def password_requirements(assigns) do
    ~H"""
    <div
      id="password-requirements"
      class="mt-3 rounded-xl border border-black/[0.06] bg-[#fafafa] px-4 py-3"
    >
      <p class="font-mono text-[0.66rem] uppercase tracking-[0.18em] text-black/40">
        Password Requirements
      </p>
      <ul class="mt-3 space-y-2">
        <li
          :for={requirement <- @requirements}
          id={"password-requirement-#{requirement.id}"}
          class={[
            "flex items-center gap-2 font-mono text-[0.72rem] transition-colors",
            requirement.met? && "text-emerald-600",
            !requirement.met? && "text-black/40"
          ]}
        >
          <.icon
            name={if(requirement.met?, do: "hero-check-circle", else: "hero-x-circle")}
            class={[
              "h-4 w-4 shrink-0",
              requirement.met? && "text-emerald-500",
              !requirement.met? && "text-black/20"
            ]}
          />
          <span>{requirement.label}</span>
        </li>
      </ul>
    </div>
    """
  end
end
