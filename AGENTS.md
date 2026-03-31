This is a web application written using the Phoenix web framework.

## Git Workflow (MANDATORY)

**CRITICAL: All AI agents MUST follow this trunk-based branching strategy when creating PRs:**

## ZAQ Project Context

### What is ZAQ
AI-powered company brain. Ingests documents, builds a knowledge base, answers questions from humans and AI agents with cited responses. Deployed on-premise with a customer-provided LLM endpoint.

### Tech Stack
| Layer | Technology |
| -------- | ---------- |
| Language | Elixir 1.19.5 / Erlang OTP 28 |
| Web | Phoenix 1.7, Phoenix LiveView |
| Database | PostgreSQL 16+ with pgvector |
| Jobs | Oban |
| Assets | Node.js 20+ |
| LLM | Customer-provided, configured per deployment |

### Project Structure
```
lib/
├── zaq/
│   ├── accounts/         # Users, roles, auth
│   ├── agent/            # RAG, LLM, answering, retrieval
│   ├── channels/         # Shared infra + adapter implementations
│   │   ├── ingestion/    # Google Drive, SharePoint (not yet implemented)
│   │   └── retrieval/    # Mattermost ✅, Slack/Email planned
│   ├── embedding/        # Embedding client (standalone)
│   ├── engine/           # Orchestrator — adapter contracts + supervisors + Conversations context
│   ├── ingestion/        # Document processing, chunking, Oban jobs
│   ├── license/          # License verification, feature gating
│   ├── node_router.ex    # Routes RPC calls by role
│   └── application.ex   # Role-based OTP startup
├── zaq_web/
│   ├── live/bo/
│   │   ├── accounts/     # Users + Roles CRUD
│   │   ├── ai/           # Ingestion, Ontology, Prompt Templates, Diagnostics
│   │   ├── communication/# Channels, History, Playground, Conversations
│   │   └── system/       # Password, License
│   ├── controllers/
│   ├── plugs/auth.ex
│   └── router.ex
```

### Documentation Map

Use these docs first when working in the corresponding area:

- `docs/system-config.md` — system settings, secret encryption, key handling
- `docs/channels.md` — channel architecture, retrieval/ingestion adapter model
- `docs/agent.md` — agent pipeline and service boundaries
- `docs/ingestion.md` — ingestion pipeline and chunking flow
- `docs/telemetry.md` — telemetry runtime behavior and naming
- `docs/bo-auth.md` — BO authentication and authorization flow
- `docs/license.md` — license loading and feature gating

When a task touches keys, tokens, passwords, or encrypted config fields, always consult `docs/system-config.md` before coding.

### Key Conventions
- Contexts: `lib/zaq/` (e.g. `Zaq.Accounts`, `Zaq.Ingestion`)
- LiveViews: `lib/zaq_web/live/bo/<section>/` with paired `.html.heex`
- LiveView modules: `ZaqWeb.Live.BO.<Section>.<n>Live`
- Context functions: `create_x/1`, `update_x/2`, `delete_x/1`
- Schemas: `Zaq.<Context>.<Entity>` (e.g. `Zaq.Accounts.User`)
- Channel adapters: `Zaq.Channels.<Kind>.<Provider>`
- Background jobs: Oban workers under `lib/zaq/ingestion/`
- Run `mix precommit` before committing to validate changes
- Do not replace `mix precommit` with ad-hoc checks; if it cannot fully run, report what was skipped and why

#### Conversations Context (`Zaq.Engine.Conversations`)
Persists every Q&A exchange as a structured Conversation with Messages.

- Module: `lib/zaq/engine/conversations.ex`
- Schemas: `lib/zaq/engine/conversations/` (Conversation, Message, MessageRating, ConversationShare)
- Oban worker: `Zaq.Engine.Conversations.TokenUsageAggregator` (queue: `:conversations`)
- BO routes: `GET /bo/conversations`, `GET /bo/conversations/:id`
- LiveViews: `ZaqWeb.Live.BO.Communication.ConversationsLive`, `ConversationDetailLive`
- All BO calls MUST go through `NodeRouter.call(:engine, Zaq.Engine.Conversations, ...)`
- `users` table uses integer PKs — FK fields in conversation schemas use `type: :integer`
- Anonymous channel users identified by `channel_user_id + channel_type` (no `user_id`)

### Multi-Node Roles
Services start based on `:roles` config or `ROLES` env var (`ROLES` takes priority).

| Role | Starts |
| ------------ | ------ |
| `:all` | All services (default) |
| `:engine` | `Zaq.Engine.Supervisor` |
| `:agent` | `Zaq.Agent.Supervisor` |
| `:ingestion` | `Zaq.Ingestion.Supervisor` |
| `:channels` | `Zaq.Channels.Supervisor` |
| `:bo` | `ZaqWeb.Endpoint` |

### Engine
Orchestrates ZAQ. Owns behaviour contracts and adapter lifecycle.

- `Zaq.Engine.IngestionChannel` — contract for ingestion adapters
- `Zaq.Engine.RetrievalChannel` — contract for retrieval adapters
- `Zaq.Engine.IngestionSupervisor` / `RetrievalSupervisor` — loads configs from DB, starts adapters dynamically

Registered adapters:
- Retrieval: `mattermost` ✅, `slack` / `email` (not implemented)
- Ingestion: `google_drive` / `sharepoint` (not implemented)

## General guidelines

### Development Workflows

#### 1) Bugfix Workflow (MANDATORY — follow this first for any bug)

1. Write or update an automated test that reproduces the bug.
2. Fix the code and confirm the new/updated test passes.
3. Iterate on the fix until the reproducing test passes reliably.
4. Once fixed, check code standards with `mix credo --strict`.
5. Confirm no regression by running the full test suite in this order:
   - unit tests first
   - e2e tests second

### Branch Hierarchy
1. **feature/** branches → Code review + Unit tests → merge into `main`
2. **hotfix/** branches → Urgent post-release fixes → merge into `main`
3. **main** branch → Stable source of truth → release PR/tag → Docker image + docs update

### AI Agent Rules
- **NEVER** push directly to `main`; all changes must go through a Pull Request
- **ALWAYS** target `main` for feature and hotfix PRs
- Branch naming: `feature/description`, `feature/issue-123-description`, or `hotfix/description`

### Semantic Versioning for Commits and PR Names

All commits and PR titles MUST follow [Conventional Commits](https://www.conventionalcommits.org/) with semantic versioning prefixes:

**Format:** `<type>(<scope>): <description>`

**Types:**
- `feat:` - New features (bumps MINOR version)
- `fix:` - Bug fixes (bumps PATCH version)
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, semicolons, etc)
- `refactor:` - Code refactoring
- `perf:` - Performance improvements
- `test:` - Adding or updating tests
- `chore:` - Build process or auxiliary tool changes

**Examples:**
```
feat(auth): add OAuth2 login support
fix(api): resolve null pointer in user endpoint
docs(readme): update installation instructions
```

**For breaking changes**, add `!` after the type or include `BREAKING CHANGE:` in the footer:
```
feat(api)!: remove deprecated v1 endpoints
```

### Current Branch Check
Before creating any PR, verify:
- Is this a feature/fix? → Use `feature/*` and target `main`
- Is this an urgent post-release patch? → Use `hotfix/*` and target `main`
- Is this a versioned release? → Managed by `release-please` from `main`


## Project guidelines

### Code Quality Standards (Debt Prevention)

These standards complement `mix precommit` and intentionally focus on architecture, maintainability, and technical debt prevention (not duplicate gate checks).

#### 1) Separation of concerns and architecture boundaries
- Keep domain and business rules in `lib/zaq/` contexts/domain modules; LiveViews/controllers/plugs/workers should orchestrate and delegate.
- BO modules in `lib/zaq_web/` must not access persistence or integrations directly; call context APIs and use `NodeRouter.call/4` for cross-service boundaries.
- Treat context internals as private implementation details. Cross-context calls should use public context functions, not internal helpers.
- Keep module responsibilities cohesive. If a module owns unrelated concerns (querying + formatting + transport), split it.

#### 2) DRY and pattern reuse
- Reuse existing context APIs, query helpers, changeset patterns, and UI components before introducing new abstractions.
- Apply a rule-of-three for extraction: duplicate twice if needed, extract shared abstractions once the pattern is stable.
- Prefer extending established project patterns instead of creating competing variants without a strong reason.
- Avoid catch-all utility modules. Helpers should be domain-scoped and intent-revealing.

#### 3) Module and API design
- Public APIs should have predictable contracts; prefer `{:ok, result}` / `{:error, reason}` for fallible operations.
- Use `raise` and bang functions only for exceptional cases or explicit bang APIs.
- Add `@spec` for public functions in contexts, behaviours, and adapters; document non-obvious invariants with `@doc`.
- Keep functions small and composable; move branching-heavy logic into focused private functions or dedicated domain modules.

#### 4) Data access and side-effect boundaries
- Keep Ecto queries and persistence logic in context/domain modules, never in LiveViews/components/templates.
- Keep HTTP/external calls in adapter/integration modules; depend on behaviours at domain boundaries.
- Preload associations when needed by rendering layers to prevent N+1 queries.
- Make Oban workers and external side-effect operations idempotent so retries are safe.

#### 5) Technical debt controls
- Any temporary shortcut must include a TODO with a linked issue and clear removal condition.
- Remove dead code and stale branches when replacing behavior; do not keep inactive paths "just in case".
- If a change intentionally diverges from established patterns, document the rationale in the PR description.

## Dev Setup
```bash
mix setup && mix phx.server   # http://localhost:4000/bo
```

### ⚡ Execution Rule
ALL related operations MUST be concurrent in a single message: batch TodoWrite, Task spawns, file reads/writes, and bash commands together. Never split related operations across messages.

### 🛠 Tool Usage
- ALWAYS use context-mode (`mcp__plugin_context-mode_context-mode__*`) for file reads, searches, and code execution
- ALWAYS use Serena (`mcp__serena__*`) for code navigation: finding symbols, reading files, replacing symbol bodies, and creating files
- Prefer `ctx_execute` over raw Bash for shell commands
- Prefer `mcp__serena__find_symbol` and `mcp__serena__get_symbols_overview` before editing any module
- Prefer `mcp__serena__replace_symbol_body` over full file rewrites

### NodeRouter — CRITICAL
All cross-service calls from BO go through `Zaq.NodeRouter`, not direct module calls.

```elixir
# ❌ WRONG — breaks multi-node
Retrieval.ask(question, opts)

# ✅ CORRECT
NodeRouter.call(:agent, Retrieval, :ask, [question, opts])
```

`NodeRouter.call/4` checks locally first, then `:rpc.call/4` on peer nodes.

### What NOT To Do
- Don't add adapters to `Zaq.Channels.Supervisor` — Engine manages adapter lifecycle
- Don't define behaviour contracts in `lib/zaq/channels/` — they belong in `lib/zaq/engine/`
- Don't assume Slack, Email, or ingestion adapters exist — only Mattermost is implemented
- Don't move `embedding/client.ex` under `agent/` without discussion
- Don't add BO routes without updating auth plug and router
- Don't hardcode LLM endpoints — customer-configured
- Don't call Agent or Ingestion modules directly from BO LiveViews — use `NodeRouter.call/4`
- Don't use `:httpoison`, `:tesla`, and `:httpc`. Use the already included and available `:req` (`Req`) library for HTTP requests.

### Sub-Agents
Agents in `.claude/agents/`. Shared memory at `.swarm/memory.json`.

`project-planner` · `api-developer` · `tdd-specialist` · `code-reviewer` · `debugger` · `refactor` · `doc-writer` · `security-scanner` · `devops-engineer` · `product-manager` · `test-runner`

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
