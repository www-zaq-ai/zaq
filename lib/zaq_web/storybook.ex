defmodule ZaqWeb.Storybook do
  use PhoenixStorybook,
    otp_app: :zaq,
    content_path: Path.expand("../../storybook", __DIR__),
    css_path: "/assets/app.css",
    js_path: "/assets/app.js",
    title: "ZAQ Design System"
end
