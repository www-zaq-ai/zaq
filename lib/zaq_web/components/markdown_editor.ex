defmodule ZaqWeb.Components.MarkdownEditor do
  @moduledoc """
  GitHub-style markdown editor with Write / Preview tabs.

  Renders a bordered box with two tabs: **Write** exposes a plain textarea,
  **Preview** server-renders the current markdown through
  `ZaqWeb.Helpers.Markdown` (Earmark + sanitization) so authors can see how the
  instructions will look before saving.

  The textarea stays mounted in both modes (hidden via CSS in preview) so its
  value always serializes with the surrounding form on submit. Preview content
  reads from `field.value`, which the host form keeps current by emitting a
  `phx-change` validate event as the author types.

  ## Usage

      <.markdown_editor
        id="skill-body-input"
        field={@form[:body]}
        preview={@body_preview}
        toggle_event="toggle_body_preview"
        placeholder="Markdown instructions..."
      />

  The host LiveView must handle `toggle_event`, flipping a boolean assign from
  the `"mode"` param (`"preview"` / `"write"`).
  """

  use ZaqWeb, :html

  alias ZaqWeb.Helpers.Markdown

  @doc """
  Renders the markdown editor.

  Expects a `Phoenix.HTML.FormField` and a `preview` boolean controlled by the
  host LiveView. Emits `toggle_event` (`phx-click`) with a `"mode"` value of
  `"write"` or `"preview"`.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :preview, :boolean, default: false
  attr :toggle_event, :string, required: true
  attr :id, :string, default: nil
  attr :rows, :integer, default: 10
  attr :placeholder, :string, default: ""

  def markdown_editor(assigns) do
    assigns = assign(assigns, :body_value, assigns.field.value || "")

    ~H"""
    <div class="zaq-md-editor">
      <div class="zaq-md-editor__tabs">
        <button
          type="button"
          phx-click={@toggle_event}
          phx-value-mode="write"
          class={["zaq-md-editor__tab", not @preview && "zaq-md-editor__tab--active"]}
        >
          Write
        </button>
        <button
          type="button"
          phx-click={@toggle_event}
          phx-value-mode="preview"
          class={["zaq-md-editor__tab", @preview && "zaq-md-editor__tab--active"]}
        >
          Preview
        </button>
      </div>

      <textarea
        id={@id}
        name={@field.name}
        rows={@rows}
        placeholder={@placeholder}
        class={["zaq-md-editor__textarea", @preview && "zaq-md-editor__textarea--hidden"]}
      >{@body_value}</textarea>

      <div
        :if={@preview}
        id={@id && "#{@id}-preview"}
        phx-hook="MarkdownHighlight"
        class="markdown-preview zaq-md-editor__preview"
      >
        <%= if String.trim(@body_value) == "" do %>
          <p class="zaq-md-editor__empty">Nothing to preview.</p>
        <% else %>
          {Phoenix.HTML.raw(Markdown.render(@body_value))}
        <% end %>
      </div>
    </div>
    """
  end
end
