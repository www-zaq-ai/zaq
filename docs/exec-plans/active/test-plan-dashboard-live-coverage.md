# Test Coverage Plan — DashboardLive Uncovered Lines

**File:** `lib/zaq_web/live/bo/dashboard_live.ex`
**Test file to edit:** `test/zaq_web/live/bo/dashboard_live_test.exs`
**Uncovered lines:** 74, 108, 132, 171, 182, 185, 230

---

## Summary of uncovered code

| Line | Code | Branch |
|------|------|--------|
| 74 | `handle_event("close_portal_consent_modal", ...)` | closes modal, clears error |
| 108 | `{:error, _reason}` in `accept_portal_consent` | non-changeset HTTP/network failure |
| 132 | `_ ->` in `email_error_message/1` | changeset has no `:email` error key |
| 171 | `node_running_supervisor?/2` remote-node clause | `:rpc.call` path for peer nodes |
| 182 | `_ ->` in `load_main_dashboard_metrics` | NodeRouter returns unexpected shape |
| 185 | `rescue` in `load_main_dashboard_metrics` | NodeRouter raises an exception |
| 230 | `Map.get(:metrics, [])` in `default_telemetry_metric_cards/0` | final pipeline step, fallback metric cards |

Lines 182, 185, and 230 are all reachable by controlling what `NodeRouter.invoke/4` returns or raises.
Lines 182 and 230 are hit together when the NodeRouter response does not match the expected shape.

---

## Test scenarios

### 1. `close_portal_consent_modal` event — Line 74

**Describe block:** `"portal consent modal"` (already exists)

**New test:**
```
test "close_portal_consent_modal hides the modal and clears any error", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
  render_click(view, "show_portal_consent", %{})
  html = render_click(view, "close_portal_consent_modal", %{})
  # modal is gone — button that opens it should be back, not the modal's accept button
  refute html =~ "Accept"
end
```

**Why:** Directly fires `close_portal_consent_modal` after opening the modal. This hits line 74 and verifies both `show_portal_consent_modal: false` and `portal_provision_error: nil` are set.

---

### 2. `accept_portal_consent` — non-changeset HTTP error — Line 108

**Describe block:** `"portal consent modal"` (already exists)

**New test:**
```
test "shows a generic error when portal provisioning fails with a network error", %{conn: conn} do
  Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
    Req.Test.transport_error(conn, :econnrefused)
  end)

  {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
  render_click(view, "show_portal_consent", %{})
  html = render_click(view, "accept_portal_consent", %{})

  assert html =~ "Could not reach the ZAQ portal. Please try again later."
end
```

**Context:** Uses the no-email user setup from the existing `"portal consent modal"` describe-block `setup`. The `Req.Test.stub` triggers `{:error, _reason}` from `Accounts.provision_portal_for_user/1`, which is the generic HTTP-level failure branch (line 108).

---

### 3. `email_error_message/1` fallback — Line 132

**Describe block:** `"portal consent modal"` (already exists)

**New test:** The fallback `_ ->` branch fires when `Accounts.provision_portal_for_user/1` returns `{:error, %Ecto.Changeset{}}` whose `:errors` list does **not** contain an `:email` key (e.g. a base-level error). Trigger this by stubbing `Accounts.update_user/2` to return a changeset with a different error key, or by injecting a changeset directly.

Simpler approach: add a base error (not email) to the changeset. Since `Accounts.update_user/2` validates email format, use an empty string which may produce an email-format changeset error, OR use `Mox` / direct changeset construction.

Pragmatic approach — construct the changeset in test via `Accounts.User.changeset/2` with a conflicting unique constraint that has no `:email` error key. However the cleanest approach without introducing Mox is:

```
test "shows fallback validation message when changeset has no email error", %{conn: conn} do
  # Stub update_user to return a changeset error on a non-email field
  # The fallback _ -> branch in email_error_message/1 fires
  # Use a valid email but make provision_portal_for_user return a non-email changeset error
  Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
    Req.Test.json(conn, %{"error" => "forbidden"}, status: 403)
  end)

  {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
  render_click(view, "show_portal_consent", %{})
  render_change(view, "portal_consent_email_change", %{"email" => "valid@example.com"})
  html = render_click(view, "accept_portal_consent", %{})

  assert html =~ "Please enter a valid email address."
end
```

**Alternative if the above hits line 108 instead:** Instrument `Accounts.provision_portal_for_user/1` to return `{:error, Ecto.Changeset.add_error(changeset, :base, "some error")}` using a test stub. If `Mox` is already configured for `Accounts`, use it; otherwise add an application env override for this test only to swap the implementation. Check `test/support/` for existing mock patterns before choosing.

---

### 4. Remote-node supervisor detection — Line 171

**Describe block:** new `"service detection"` describe block OR add to existing `"mount"` describe block.

**New test:**
```
test "detects a remote peer node supervisor via rpc", %{conn: conn} do
  # Temporarily add a fake peer node to Node.list() by mocking via :erlang.nodes/0
  # Since this is hard to inject, use :meck or test the indirect effect:
  # The node_running_supervisor?/2 remote-clause fires whenever Node.list() is non-empty.
  # In a single-node test env, Node.list() is [] so only the local clause fires.
  # Strategy: call the private function via :erlang.apply/3 with a node name != node()
  # to trigger the remote path. OR accept this line is only reachable in multi-node env
  # and cover it via a focused unit test on the private function using send/apply.

  # Recommended approach — test the private function directly using module internals:
  # Since Elixir doesn't expose private functions, we test the observable effect.
  # Stub Node.list() response by monkey-patching via :meck in the test setup:

  :meck.new(:erlang, [:passthrough])
  :meck.expect(:erlang, :nodes, fn :visible -> [:fake@remote] end)

  on_exit(fn -> :meck.unload(:erlang) end)

  # With a fake peer, detect_running_services will call node_running_supervisor?(:fake@remote, supervisor)
  # which hits the remote clause (line 171). The :rpc.call will return nil (node not real),
  # so result is {false, nil} — service shows as inactive, which is the same as the default.
  {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
  assert html =~ "Engine"
end
```

**Note:** If `:meck` is not in deps, an alternative is to accept this line as infrastructure-only and annotate it as an `# coveralls-ignore-next-line` exclusion after discussion with the team. Check `mix.exs` for `:meck` before implementing.

---

### 5. `load_main_dashboard_metrics` — unexpected shape branch — Lines 182, 230

**Describe block:** `"mount"` (already exists)

**New test:**
```
test "renders default metric cards when NodeRouter returns an unexpected shape", %{conn: conn} do
  # Patch NodeRouter to return a map that does not match the expected structure.
  # Since NodeRouter.invoke/4 is called during mount, we need to intercept it.
  # Check if NodeRouter has a Behaviour/Mox mock in test support first.
  # If yes, use: expect(NodeRouter.Mock, :invoke, fn _, _, _, _ -> %{unexpected: true} end)
  # If no, override via Application.put_env or use Req.Test pattern for the underlying HTTP client.

  # Simplest integration approach: NodeRouter.invoke on :engine in test env likely
  # falls back to a local call (no engine node running). If it currently raises,
  # line 185 is already hit. To hit line 182 specifically, ensure NodeRouter returns
  # a value (not raises) that doesn't match the metric_cards_chart pattern.
  # Verify by checking what NodeRouter.invoke returns in the test env during mount.

  {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
  # default metric cards are rendered (0 values)
  assert has_element?(view, "#dashboard-metric-documents-ingested")
end
```

**Investigation note:** Run a test with `IO.inspect(NodeRouter.invoke(:engine, Telemetry, :load_main_dashboard_metrics, [%{range: "30d"}]))` in a test to see whether the test env hits line 182 (returns wrong shape) or line 185 (raises). This determines which branch is already covered and which needs explicit triggering.

---

### 6. `load_main_dashboard_metrics` — rescue clause — Line 185

**Describe block:** `"mount"` (already exists)

**New test:**
```
test "renders default metric cards when NodeRouter raises during mount", %{conn: conn} do
  # Force NodeRouter.invoke to raise. Options:
  # a) If NodeRouter has a Behaviour mock (Mox), stub it to raise RuntimeError.
  # b) Without Mox: temporarily configure the NodeRouter implementation in Application env
  #    to point to a test stub module that raises.

  # If NodeRouter uses a configurable impl:
  original = Application.get_env(:zaq, Zaq.NodeRouter, [])
  Application.put_env(:zaq, Zaq.NodeRouter, impl: NodeRouterStub.Raising)
  on_exit(fn -> Application.put_env(:zaq, Zaq.NodeRouter, original) end)

  {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
  assert html =~ "Engine"
  # default metric cards still render (rescue handled gracefully)
  assert has_element?(view, "#dashboard-metric-documents-ingested")
end
```

**If NodeRouter has no configurable stub:** check `test/support/` for a `NodeRouter` mock or `Zaq.NodeRouter.Behaviour` test impl, and use it.

---

## Helpers and mocks to reuse

| Helper/Mock | Location | Used for |
|---|---|---|
| `user_fixture/1` | `Zaq.AccountsFixtures` | Creating test users |
| `init_test_session/2` | `ConnCase` / `Plug.Test` | Authenticating conn |
| `Req.Test.stub/2` | Req library | Stubbing `UserPortal.Client` HTTP calls |
| `Req.Test.transport_error/2` | Req library | Simulating network errors (line 108) |
| no-email user setup block | Existing `"portal consent modal"` describe | Reuse for lines 74, 108, 132 |

---

## Implementation order (least to most effort)

1. **Line 74** — trivial: one `render_click` call
2. **Lines 182/230** — verify what NodeRouter returns in test env; likely a simple mount test
3. **Line 108** — `Req.Test.transport_error` stub
4. **Line 132** — determine if HTTP 4xx response from portal produces a non-email changeset error
5. **Line 185** — find NodeRouter stub mechanism; may need a new test-only module
6. **Line 171** — most complex; requires `:meck` or team decision to exclude

---

## Confidence notes

- Lines 74, 108 are high-confidence: straightforward event tests with existing helpers.
- Lines 182, 185, 230 share root cause; once NodeRouter's test behavior is confirmed, one or two tests cover all three.
- Line 132 depends on what error shape `provision_portal_for_user` can return.
- Line 171 (remote RPC path) may require `:meck` or a `coveralls-ignore` annotation if `:meck` is not in deps.
