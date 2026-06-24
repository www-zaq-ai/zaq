defmodule Storybook.Components.Forms.Button do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Button.button/1

  def description do
    "BO action button (`btn.css`). Variants: `:primary`, `:secondary`, `:ghost`, `:tertiary`. " <>
      "Shapes: `:default` or `:pill` (secondary chips). Optional `icon` / `icon_only`. " <>
      "Tertiary: `active`, `danger`. Any variant supports `loading` + `loading_label` for async `phx-click`. " <>
      "Navigation: `navigate`, `href`, or `patch`."
  end

  def container do
    {:div,
     style:
       "padding: var(--zaq-scale-32); background: var(--zaq-surface-color-base); color: var(--zaq-text-color-body-default); display: flex; flex-direction: column; gap: var(--zaq-scale-24); align-items: flex-start; flex-wrap: wrap;"}
  end

  def variations do
    [
      primary_variations(),
      secondary_variations(),
      ghost_variations(),
      tertiary_variations(),
      pill_variations(),
      loading_variations(),
      navigate_variations()
    ]
  end

  defp primary_variations do
    %VariationGroup{
      id: :primary,
      description: "variant={:primary}",
      variations: [
        %Variation{id: :text, description: "Text", slots: ["Confirm"]},
        %Variation{
          id: :disabled,
          description: "Disabled",
          attributes: %{disabled: true},
          slots: ["Unavailable"]
        },
        %Variation{
          id: :with_icon,
          description: "With icon",
          attributes: %{icon: "hero-x-mark"},
          slots: ["Dismiss"]
        },
        %Variation{
          id: :icon_only,
          description: "Icon only",
          attributes: %{
            icon_only: true,
            icon: "hero-x-mark",
            "aria-label": "Dismiss",
            title: "Dismiss"
          },
          slots: []
        }
      ]
    }
  end

  defp secondary_variations do
    %VariationGroup{
      id: :secondary,
      description: "variant={:secondary}",
      variations: [
        %Variation{
          id: :text,
          description: "Text",
          attributes: %{variant: :secondary},
          slots: ["Cancel"]
        },
        %Variation{
          id: :disabled,
          description: "Disabled",
          attributes: %{variant: :secondary, disabled: true},
          slots: ["Unavailable"]
        },
        %Variation{
          id: :with_icon,
          description: "With icon",
          attributes: %{variant: :secondary, icon: "hero-trash"},
          slots: ["Delete"]
        },
        %Variation{
          id: :icon_only,
          description: "Icon only",
          attributes: %{
            variant: :secondary,
            icon_only: true,
            icon: "hero-trash",
            "aria-label": "Delete",
            title: "Delete"
          },
          slots: []
        }
      ]
    }
  end

  defp ghost_variations do
    %VariationGroup{
      id: :ghost,
      description: "variant={:ghost}",
      variations: [
        %Variation{
          id: :text,
          description: "Text",
          attributes: %{variant: :ghost},
          slots: ["Dismiss"]
        },
        %Variation{
          id: :disabled,
          description: "Disabled",
          attributes: %{variant: :ghost, disabled: true},
          slots: ["Unavailable"]
        },
        %Variation{
          id: :with_icon,
          description: "With icon",
          attributes: %{variant: :ghost, icon: "hero-x-mark"},
          slots: ["Dismiss"]
        },
        %Variation{
          id: :icon_only,
          description: "Icon only",
          attributes: %{
            variant: :ghost,
            icon_only: true,
            icon: "hero-x-mark",
            "aria-label": "Dismiss",
            title: "Dismiss"
          },
          slots: []
        }
      ]
    }
  end

  defp tertiary_variations do
    %VariationGroup{
      id: :tertiary,
      description: "variant={:tertiary}",
      variations: [
        %Variation{
          id: :text,
          description: "Resting",
          attributes: %{variant: :tertiary},
          slots: ["Filter"]
        },
        %Variation{
          id: :active,
          description: "Active",
          attributes: %{variant: :tertiary, active: true},
          slots: ["Filter"]
        },
        %Variation{
          id: :danger,
          description: "Danger",
          attributes: %{variant: :tertiary, danger: true},
          slots: ["Delete"]
        },
        %Variation{
          id: :disabled,
          description: "Disabled",
          attributes: %{variant: :tertiary, disabled: true},
          slots: ["Unavailable"]
        },
        %Variation{
          id: :with_icon,
          description: "With icon",
          attributes: %{variant: :tertiary, icon: "hero-folder"},
          slots: ["Move"]
        },
        %Variation{
          id: :icon_only,
          description: "Icon only",
          attributes: %{
            variant: :tertiary,
            icon_only: true,
            icon: "hero-trash",
            danger: true,
            "aria-label": "Delete",
            title: "Delete"
          },
          slots: []
        }
      ]
    }
  end

  defp pill_variations do
    %VariationGroup{
      id: :pill,
      description: "shape={:pill} + variant={:secondary}",
      variations: [
        %Variation{
          id: :text,
          description: "Resting",
          attributes: %{shape: :pill, variant: :secondary},
          slots: ["Suggested prompt"]
        },
        %Variation{
          id: :disabled,
          description: "Disabled",
          attributes: %{shape: :pill, variant: :secondary, disabled: true},
          slots: ["Unavailable"]
        }
      ]
    }
  end

  defp loading_variations do
    %VariationGroup{
      id: :loading,
      description: "loading — attach `phx-click` at call site; click in browser to see spinner",
      variations: [
        %Variation{
          id: :primary,
          description: "Primary loading",
          attributes: %{loading: true, loading_label: "Running…", phx_click: "demo_run"},
          slots: ["Run diagnostics"]
        },
        %Variation{
          id: :secondary,
          description: "Secondary loading",
          attributes: %{
            variant: :secondary,
            loading: true,
            loading_label: "Saving…",
            phx_click: "demo_save"
          },
          slots: ["Save changes"]
        },
        %Variation{
          id: :ghost_with_icon,
          description: "Ghost with icon",
          attributes: %{
            variant: :ghost,
            icon: "hero-arrow-path",
            loading: true,
            loading_label: "Testing…",
            phx_click: "demo_test"
          },
          slots: ["Test"]
        },
        %Variation{
          id: :tertiary_danger,
          description: "Tertiary danger loading",
          attributes: %{
            variant: :tertiary,
            danger: true,
            loading: true,
            loading_label: "Deleting…",
            phx_click: "demo_delete"
          },
          slots: ["Delete"]
        }
      ]
    }
  end

  defp navigate_variations do
    %VariationGroup{
      id: :navigate,
      description: "Navigation as button",
      variations: [
        %Variation{
          id: :secondary,
          description: "navigate=",
          attributes: %{variant: :secondary, navigate: "/bo/dashboard"},
          slots: ["Go to dashboard"]
        },
        %Variation{
          id: :primary,
          description: "Primary navigate",
          attributes: %{navigate: "/bo/dashboard"},
          slots: ["Open dashboard"]
        }
      ]
    }
  end
end
