defmodule ZaqWeb.Storybook do
  @moduledoc false
  use PhoenixStorybook,
    otp_app: :zaq,
    content_path: Path.expand("../../../storybook", __DIR__),
    css_path: "/assets/css/app.dev.css",
    js_path: "/assets/js/storybook.js",
    title: "ZAQ Design System",
    color_mode: true,
    color_mode_sandbox_dark_class: "dark",
    sandbox_class: "zaq-sandbox"
end
