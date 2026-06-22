defmodule Storybook.Components.DesignSystem.SecretInput do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.SecretInput.secret_input/1

  def description,
    do: "Password or token field with show/hide eye toggle and optional field errors."

  def variations do
    [
      %VariationGroup{
        id: :default,
        description: "Secret input",
        variations: [
          %Variation{
            id: :empty,
            description: "Empty",
            attributes: %{
              id: "api-key",
              name: "api_key",
              value: "",
              placeholder: "sk-…"
            }
          },
          %Variation{
            id: :filled,
            description: "Filled",
            attributes: %{
              id: "api-key-filled",
              name: "api_key",
              value: "sk-live-xxxxxxxxxxxx"
            }
          },
          %Variation{
            id: :custom_classes,
            description: "Custom classes (login-style)",
            attributes: %{
              id: "login-password",
              name: "password",
              value: "",
              placeholder: "••••••••",
              input_class:
                "block w-full bg-slate-50 border border-slate-200 rounded-xl px-4 py-3.5 pr-12 text-slate-700 placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-cyan-500/20 focus:border-cyan-500 transition-all text-sm",
              button_class:
                "absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600 transition-colors focus:outline-none"
            }
          }
        ]
      },
      %VariationGroup{
        id: :errors,
        description: "With validation errors",
        variations: [
          %Variation{
            id: :with_error,
            description: "Field error",
            attributes: %{
              id: "token",
              name: "token",
              value: "",
              errors: ["can't be blank"]
            }
          }
        ]
      }
    ]
  end
end
