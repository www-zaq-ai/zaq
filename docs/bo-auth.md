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
- Logout clears session

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
