defmodule ZaqWeb.Components.DesignSystem.IngestionFileIcon do
  @moduledoc """
  Extension-specific file icons for the BO ingestion file browser.
  """

  use Phoenix.Component

  @doc "Renders a file-type icon based on the file extension."
  attr :name, :string, required: true
  attr :class, :string, default: "w-4 h-4"

  def file_icon(%{name: name} = assigns) do
    gradient_id = "img-gradient-#{:erlang.phash2(name)}"

    assigns =
      assigns
      |> assign(:ext, Path.extname(name) |> String.downcase())
      |> assign(:gradient_id, gradient_id)

    ~H"""
    <%= cond do %>
      <% @ext == ".pdf" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#FEE2E2"
            stroke="#DC2626"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#DC2626" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#DC2626" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="20"
          >
            PDF
          </text>
        </svg>
      <% @ext == ".pptx" -> %>
        <svg class={@class} xmlns="http://www.w3.org/2000/svg" viewBox="3 3 42 42">
          <path fill="#FF8A65" d="M41,10H25v28h16c0.553,0,1-0.447,1-1V11C42,10.447,41.553,10,41,10z" />
          <path
            fill="#FBE9E7"
            d="M24 29H38V31H24zM24 33H38V35H24zM30 15c-3.313 0-6 2.687-6 6s2.687 6 6 6 6-2.687 6-6h-6V15z"
          />
          <path fill="#FBE9E7" d="M32,13v6h6C38,15.687,35.313,13,32,13z" />
          <path fill="#E64A19" d="M27 42L6 38 6 10 27 6z" />
          <path
            fill="#FFF"
            d="M16.828,17H12v14h3v-4.823h1.552c1.655,0,2.976-0.436,3.965-1.304c0.988-0.869,1.484-2.007,1.482-3.412C22,18.487,20.275,17,16.828,17z M16.294,23.785H15v-4.364h1.294c1.641,0,2.461,0.72,2.461,2.158C18.755,23.051,17.935,23.785,16.294,23.785z"
          />
        </svg>
      <% @ext == ".docx" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#EFF6FF"
            stroke="#2563EB"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#2563EB" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#2563EB" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="17"
          >
            DOCX
          </text>
        </svg>
      <% @ext in [".xlsx", ".xls"] -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#F0FDF4"
            stroke="#16A34A"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#16A34A" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#16A34A" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="17"
          >
            XLSX
          </text>
        </svg>
      <% @ext in [".png", ".jpg", ".jpeg"] -> %>
        <svg
          class={@class}
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 32 32"
          fill="none"
        >
          <path
            d="M25.6 0H6.4C2.86538 0 0 2.86538 0 6.4V25.6C0 29.1346 2.86538 32 6.4 32H25.6C29.1346 32 32 29.1346 32 25.6V6.4C32 2.86538 29.1346 0 25.6 0Z"
            fill={"url(##{@gradient_id})"}
          />
          <path
            d="M5.9577 24.8845C5.42578 25.9483 6.19937 27.2 7.38878 27.2H18.2111C19.4005 27.2 20.1741 25.9483 19.6422 24.8845L14.231 14.0622C13.6414 12.8829 11.9585 12.8829 11.3688 14.0622L5.9577 24.8845Z"
            fill="white"
          />
          <path
            d="M15.5577 24.8845C15.0258 25.9483 15.7994 27.2 16.9888 27.2H24.6111C25.8005 27.2 26.5741 25.9483 26.0422 24.8845L22.231 17.2622C21.6414 16.0829 19.9585 16.0829 19.3688 17.2622L15.5577 24.8845Z"
            fill="white"
            fill-opacity="0.6"
          />
          <path
            d="M24.0002 11.2C25.7675 11.2 27.2002 9.76726 27.2002 7.99995C27.2002 6.23264 25.7675 4.79995 24.0002 4.79995C22.2329 4.79995 20.8002 6.23264 20.8002 7.99995C20.8002 9.76726 22.2329 11.2 24.0002 11.2Z"
            fill="white"
          />
          <defs>
            <linearGradient
              id={@gradient_id}
              x1="16"
              y1="0"
              x2="16"
              y2="32"
              gradientUnits="userSpaceOnUse"
            >
              <stop stop-color="#00E676" />
              <stop offset="1" stop-color="#00C853" />
            </linearGradient>
          </defs>
        </svg>
      <% @ext == ".csv" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#ECFDF5"
            stroke="#059669"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#059669" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#059669" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="20"
          >
            CSV
          </text>
        </svg>
      <% @ext == ".md" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#ECFEFF"
            stroke="#0891B2"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#0891B2" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#0891B2" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="22"
          >
            MD
          </text>
        </svg>
      <% true -> %>
        <%!-- Generic document icon --%>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
          <polyline points="14 2 14 8 20 8" />
        </svg>
    <% end %>
    """
  end

  def file_icon_color(name) do
    case Path.extname(name) |> String.downcase() do
      ".pdf" -> "text-red-400"
      ".md" -> "zaq-text-accent"
      ".xlsx" -> "text-emerald-500"
      ".csv" -> "text-emerald-400"
      ".docx" -> "text-blue-400"
      ".pptx" -> "text-orange-400"
      _ -> "text-black/30"
    end
  end
end
