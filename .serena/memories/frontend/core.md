# BO source map

- Owners: [design system](../../../DESIGN.md), [BO mechanics](../../../docs/bo-components.md), [BO auth](../../../docs/services/bo-auth.md). Source: `lib/zaq_web/live/bo/`, components/, router.ex and plugs/.
- Endpoint presence doesn't imply BO access: Channels nodes also host HTTP. Router role/auth plugs and LiveView AuthHook are separate safeguards; workflows add WorkflowGuard.
- BOLayout owns page shell/sidebar/flash. Pass current_path for navigation; don't render a second flash group. Check DesignSystem inventory/Storybook before adding markup; CSS remains styling authority per DESIGN.md.
- UI delegates domain work through Event/dispatch. Persistence, provider clients and business policy don't belong in LiveViews.
- Extraction, styling migration and replacement are distinct approval-gated operations; extraction alone doesn't rewire source LiveViews.
- Browser tests: `test/e2e/`; fixtures: `test/support/e2e/`. Commands and environment: [E2E guide](../../../docs/e2e-testing.md). Feature authoring approval versus existing-test execution: `mem:task_completion`.
