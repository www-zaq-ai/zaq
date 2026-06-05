defmodule Storybook.Foundations.Spacing do
  use PhoenixStorybook.Story, :page

  def description, do: "ZAQ spacing scale — foundation tokens from 0 to 1440px."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 0.5rem; max-width: 600px;">
      <div style="background: rgba(255, 200, 60, 0.1); border: 1px solid rgba(255, 180, 0, 0.3); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit; margin-bottom: 1rem;">
        <strong style="font-weight: 600;">Foundation tokens are source values only.</strong>
        They exist to define semantic tokens — never reference them directly in components or pages.
        Use <strong style="font-weight: 600;">semantic tokens</strong>
        (e.g. <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--zaq-surface-color-base</code>) in all UI code.
      </div>
      <p style="font-size: 0.75rem; opacity: 0.45; margin-bottom: 1.5rem;">
        Base-8 grid. Each bar represents the token's raw pixel value.
      </p>

      <.scale_row token="--zaq-scale-0" label="0" px="0px" />
      <.scale_row token="--zaq-scale-2" label="2" px="2px" />
      <.scale_row token="--zaq-scale-4" label="4" px="4px" />
      <.scale_row token="--zaq-scale-8" label="8" px="8px" />
      <.scale_row token="--zaq-scale-10" label="10" px="10px" />
      <.scale_row token="--zaq-scale-12" label="12" px="12px" note="small text only" />
      <.scale_row token="--zaq-scale-14" label="14" px="14px" />
      <.scale_row token="--zaq-scale-16" label="16" px="16px" />
      <.scale_row token="--zaq-scale-20" label="20" px="20px" />
      <.scale_row token="--zaq-scale-24" label="24" px="24px" />
      <.scale_row token="--zaq-scale-32" label="32" px="32px" />
      <.scale_row token="--zaq-scale-40" label="40" px="40px" />
      <.scale_row token="--zaq-scale-48" label="48" px="48px" />
      <.scale_row token="--zaq-scale-56" label="56" px="56px" />
      <.scale_row token="--zaq-scale-64" label="64" px="64px" />
      <.scale_row token="--zaq-scale-72" label="72" px="72px" />
      <.scale_row token="--zaq-scale-80" label="80" px="80px" />
      <.scale_row token="--zaq-scale-88" label="88" px="88px" />
      <.scale_row token="--zaq-scale-96" label="96" px="96px" />
      <.scale_row token="--zaq-scale-120" label="120" px="120px" />
      <.scale_row token="--zaq-scale-999" label="999" px="999px" note="pill / full round" />
      <.scale_row token="--zaq-scale-1440" label="1440" px="1440px" note="max page width" />
    </div>
    """
  end

  defp scale_row(assigns) do
    assigns = Map.put_new(assigns, :note, nil)

    ~H"""
    <div style="display: grid; grid-template-columns: 48px 1fr 140px; align-items: center; gap: 1rem; padding: 0.3rem 0;">
      <span style="font-family: ui-monospace, monospace; font-size: 0.7rem; opacity: 0.5; text-align: right;">
        {@px}
      </span>
      <div style="overflow: hidden; min-width: 0;">
        <div style={"height: 12px; border-radius: 3px; background: var(--zaq-color-blue-400, #1a6ef5); width: var(#{@token}, #{@px}); max-width: 100%; min-width: 2px;"}>
        </div>
      </div>
      <div style="display: flex; flex-direction: column; gap: 0.1rem;">
        <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.35;">
          {@token}
        </span>
        <%= if @note do %>
          <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.25; white-space: nowrap;">
            {@note}
          </span>
        <% end %>
      </div>
    </div>
    """
  end
end
