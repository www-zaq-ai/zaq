# Phoenix Guidelines

## Phoenix

- Remember Phoenix router `scope` blocks include an optional alias prefixed for all routes within the scope. Always be mindful of this to avoid duplicate module prefixes.
- You **never** need to create your own `alias` for route definitions — the `scope` provides it:

  ```elixir
  scope "/admin", AppWeb.Admin do
    pipe_through :browser
    live "/users", UserLive, :index  # points to AppWeb.Admin.UserLive
  end
  ```

- `Phoenix.View` no longer is needed or included with Phoenix — don't use it.

---

## Phoenix v1.8

- **Always** begin LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content.
- `MyAppWeb.Layouts` is aliased in `my_app_web.ex` — no need to alias it again.
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or failed to pass `current_scope` to `<Layouts.app>`.
  - Fix by moving routes to the proper `live_session` and ensuring `current_scope` is passed.
- Phoenix v1.8 moved `<.flash_group>` to the `Layouts` module. **Forbidden** from calling `<.flash_group>` outside of `layouts.ex`.
- **Always** use the `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for icons — **never** use `Heroicons` modules.
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex`.
- If you override default input classes, no default classes are inherited — your custom classes must fully style the input.

---

## LiveView

- **Never** use deprecated `live_redirect` and `live_patch`. Use `<.link navigate={href}>`, `<.link patch={href}>`, `push_navigate`, and `push_patch`.
- **Avoid LiveComponents** unless you have a strong, specific need for them.
- LiveViews should be named with a `Live` suffix: `AppWeb.WeatherLive`.

### Streams
- **Always** use LiveView streams for collections to avoid memory issues:
  ```elixir
  stream(socket, :messages, [new_msg])                        # append
  stream(socket, :messages, [new_msg], reset: true)          # reset
  stream(socket, :messages, [new_msg], at: -1)               # prepend
  stream_delete(socket, :messages, msg)                       # delete
  ```
- Stream templates must set `phx-update="stream"` with a DOM id on the parent, and use the stream id on each child:
  ```heex
  <div id="messages" phx-update="stream">
    <div :for={{id, msg} <- @streams.messages} id={id}>{msg.text}</div>
  </div>
  ```
- Streams are not enumerable — to filter, refetch data and re-stream with `reset: true`.
- Streams do not support counting or empty states — track counts with a separate assign.
- When updating an assign that changes content inside streamed items, re-stream those items with `stream_insert`.
- **Never** use deprecated `phx-update="append"` or `phx-update="prepend"`.

### JavaScript Interop
- Always set `phx-update="ignore"` when a `phx-hook` manages its own DOM.
- Always provide a unique DOM id alongside `phx-hook`.
- **Never** write raw `<script>` tags in HEEx. Use colocated JS hook script tags:

  ```heex
  <input type="text" id="user-phone" phx-hook=".PhoneNumber" />
  <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
    export default {
      mounted() { ... }
    }
  </script>
  ```

- Colocated hook names **must always** start with a `.` prefix: `.PhoneNumber`.
- External hooks go in `assets/js/` and are passed to the `LiveSocket` constructor.
- Always return or rebind the socket on `push_event/3`.

### Forms
- **Always** use `to_form/2` assigned in the LiveView and `<.form for={@form}>` in the template.
- **Always** access form fields via `@form[:field]`, never via `@changeset[:field]`.
- **Forbidden** from accessing the changeset directly in the template.
- **Never** use `<.form let={f} ...>` — always use `<.form for={@form} ...>`.
- Always give forms an explicit, unique DOM ID: `id="todo-form"`.

---

## Phoenix HTML (HEEx)

- Always use `~H` or `.html.heex` files — **never** use `~E`.
- **Always** use `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` — never `Phoenix.HTML.form_for`.
- **Always** use `Phoenix.Component.to_form/2` for building forms.
- Always add unique DOM IDs to key elements (forms, buttons, etc).
- Elixir supports `if/else` but **not** `if/else if` or `if/elsif`. Use `cond` or `case` for multiple conditionals.
- For literal `{` or `}` in `<pre>` or `<code>` blocks, annotate the parent tag with `phx-no-curly-interpolation`.
- Always use list syntax for multiple class values:

  ```heex
  <a class={[
    "px-2 text-white",
    @some_flag && "py-5",
    if(@other_condition, do: "border-red-500", else: "border-blue-100")
  ]}>Text</a>
  ```

- **Never** use `<% Enum.each %>` for template content — always use `<%= for item <- @collection do %>`.
- HEEx comments: `<%!-- comment --%>`.
- Use `{...}` for interpolation within tag attributes and for values in tag bodies. Use `<%= ... %>` for block constructs (`if`, `cond`, `case`, `for`) within tag bodies.

---

## JS & CSS

- Use Tailwind CSS classes and custom CSS rules for all styling.
- Tailwind v4 no longer needs `tailwind.config.js`. Use this import syntax in `app.css`:

  ```css
  @import "tailwindcss" source(none);
  @source "../css";
  @source "../js";
  @source "../../lib/my_app_web";
  ```

- **Never** use `@apply` in raw CSS.
- **Always** manually write Tailwind-based components — never use daisyUI.
- Only `app.js` and `app.css` bundles are supported — import vendor deps into them, never reference external scripts/links in layouts.
- **Never** write inline `<script>custom js</script>` tags within templates.

---

## UI/UX & Design

- Produce world-class UI designs with a focus on usability, aesthetics, and modern design principles.
- Implement subtle micro-interactions (button hover effects, smooth transitions).
- Ensure clean typography, spacing, and layout balance for a refined, premium look.
- Focus on delightful details: hover effects, loading states, smooth page transitions.