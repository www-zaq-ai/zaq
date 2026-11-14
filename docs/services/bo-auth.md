# BO Authentication

## What's Done

### Database
- `roles` table with `name` and `meta` (JSONB)
- `users` table with `username`, `password_hash`, `role_id`, `must_change_password`
- Default roles seeded via migration: `super_admin`, `admin`, `staff`

### Auth Flow
- Bootstrap Back Office credentials are `admin` / `admin` on fresh databases
- Migration seeds a bootstrap super admin user (hashed password, `must_change_password: true`)
- Login POSTs to `BOSessionController`, which sets session and redirects
- Users with `must_change_password: true` are redirected to `/bo/change-password`
- Auth plug protects all `/bo/*` routes except `/bo/login` and `/bo/session`
- Auth plug enforces `must_change_password` — users cannot skip `/bo/change-password`
- `on_mount` AuthHook passes `current_user` to all protected LiveViews
- Logged-in users visiting `/bo/login` are redirected to dashboard (or change-password)
- Root `/` redirects to `/bo/login` or `/bo/dashboard` based on session
- Logout uses CSRF-protected DELETE request
- Logout and invalid-user cleanup remove only BO `user_id`, preserving the independent
  People cookie credential. People login renews the same signed HttpOnly/Lax cookie
  while preserving BO state; production cookies are Secure. Cookie transport retains
  the original browser-session lifetime (no Max-Age/Expires). People expiry is
  independently enforced by its database session row.

### BO Layout
- Shared sidebar layout component (`BOLayout`)
- Sidebar with logo, nav links (Dashboard, Users, Roles), user info, logout
- Header with page title
- Branding: `#03b6d4` accent, `#3c4b64` sidebar, white content area

### Admin CRUD
- Users: list, create (with password), edit, delete
- Roles: list, create (with JSON meta), edit, delete
- Context functions: `create_user_with_password/1`, `update_user/2`, `delete_user/1`, `update_role/2`, `delete_role/1`
- JSON meta parsing for roles (string → map)

### Guarded role mutations and policy capabilities

BO role creation/editing/deletion and assigning a role to a new/existing User
require the current `super_admin` role. The account forms dispatch confidential
`:account_administration` Engine events. The Engine boundary delegates permission
checks to `Zaq.Accounts.Administration`, which reloads authority through
`Zaq.Accounts.BOAuthorization` on every mutation. A cached privileged LiveView
actor cannot retain write authority after its persisted role is revoked.

`Administration` checks permissions and delegates execution to the existing
Accounts functions. `Accounts.update_user/2` owns the transaction, row lock,
changeset validation and persistence, without actor or permission checks. It
rejects a changed role snapshot so a role changed between permission checking
and execution cannot be restored by a previously checked same-role edit. A stale
role returns a changeset error requiring a reload. Welcome delivery reuses
`Engine.Notifications.WelcomeEmail` after successful creation, outside the write
transaction; there is no separate account-administration Action.

Same-role profile edits and the existing dedicated password-change behavior are
unchanged. Internal Accounts persistence remains reusable by installation and
other trusted domain operations; it is not a public BO authorization boundary.
Role pages remain viewable to authenticated users; visible controls are not a
mutation permission grant. This is not a general BO route-authorization system.

`Accounts.BOActor.current_user/1` owns canonical current-user validation;
`Accounts.BOAuthorization.authorize/2` is the shared named-capability evaluator
used by account and policy administration, not a clearance-context factory.
Domain boundaries request their required capability without copying role checks.

The resource-policy foundation exclusively uses BO roles without linking Users
to People. People/Teams carry confidentiality levels, not administrative authority;
portal permissions and ResourcePermission grants never authorize policy changes.
Someone needing administration receives BO access with the appropriate Role.
Super administrators have all listed capabilities; other roles can explicitly
list the following independent names in `role.meta["permissions"]`:

- `view_resource_policies`
- `add_resource_policies`
- `edit_resource_policies`
- `manage_confidentiality_defaults`
- `skip_actor_clearance`

`manage_roles` cannot be delegated through metadata: account-role administration
remains super-admin-only. `admin`, `staff`, generic `read`/`write` metadata, and
ordinary `skip_permissions` do not implicitly grant these new capabilities.

`Events.TrustedContext.from_bo_actor/1` builds a canonical independent BO actor and
issues only the narrow caller-clearance capability. It strips actor-supplied
role/bypass claims and does not grant content permission or skip channel, agent,
provider or MCP clearance. It asks the shared BO evaluator for the narrow capability;
ordinary account edits authenticate without constructing an execution context.
There are no Person/team policy-administrator grants, scopes or bootstrap.
TrustedContext can transport this separate capability;
the actual execution enforcement consumers are subsequent increments. See
[resource policies](resource-policies.md) for foundation/activation status.

### Files
```
lib/zaq/accounts.ex                          # Context (roles, users, auth, CRUD)
lib/zaq/accounts/role.ex                     # Schema
lib/zaq/accounts/user.ex                     # Schema
priv/repo/migrations/20260317091138_seed_default_roles_and_admin_user.exs
lib/zaq_web/plugs/auth.ex                    # Auth plug (session + must_change_password)
lib/zaq_web/components/bo_layout.ex          # BO sidebar layout component
lib/zaq_web/controllers/bo_session_controller.ex
lib/zaq_web/controllers/page_controller.ex   # Root redirect
lib/zaq_web/live/bo/auth_hook.ex             # on_mount hook for LiveViews
lib/zaq_web/live/bo/login_live.ex
lib/zaq_web/live/bo/change_password_live.ex
lib/zaq_web/live/bo/dashboard_live.ex
lib/zaq_web/live/bo/users_live.ex            # Users list + delete
lib/zaq_web/live/bo/user_form_live.ex        # Users create + edit
lib/zaq_web/live/bo/roles_live.ex            # Roles list + delete
lib/zaq_web/live/bo/role_form_live.ex        # Roles create + edit
```

### Tests
- `test/zaq/accounts_test.exs` — roles, users, password, authentication, CRUD, meta parsing
- `test/zaq_web/controllers/bo_session_controller_test.exs` — login, logout, redirects
- `test/zaq_web/controllers/page_controller_test.exs` — root redirect logic
- `test/zaq_web/plugs/auth_test.exs` — session check, redirect, must_change_password enforcement
- `test/zaq_web/live/bo/users_live_test.exs` — list, create, edit, delete users
- `test/zaq_web/live/bo/roles_live_test.exs` — list, create, edit, delete roles

## What's Left

### Must Do
- [ ] Add `remember me` functionality (persistent session/token)

### Should Do
- [ ] Role-based authorization plug (restrict routes by role)
- [ ] Flash messages styled consistently across BO
- [ ] Password reset flow (admin-initiated or self-service)

### Nice to Have
- [ ] Audit log for login attempts
- [ ] Session expiry / timeout
- [ ] Rate limiting on login
- [ ] Two-factor authentication
