# Completion policy entry points

- [Workflow phases 4–7](../../docs/WORKFLOW_AGENT.md#phase-4--validate) own validation timing, failure handling, coverage and final approval. Read them rather than treating this memory as an alternate checklist.
- Issue checks are `mix q` plus isolated tests; final gate is `mix precommit`. They are not interchangeable, and q does not run tests. The workflow specifies Context Mode execution and coverage/final-gate timeouts.
- [Testing handbook](../../docs/testing-approach.md#feature-e2e-approval-gate) distinguishes running existing E2E from authoring new feature journeys. New/substantially rewritten feature E2E needs explicit human UX/UI finalization approval; passing tests or merging an iteration isn't approval.
- [Documentation hygiene](../../docs/documentation.md#change-and-review-checklist) owns link/example/memory checks and refers to the same workflow for documentation-only exceptions. `serena memories check` proves reference integrity, not factual accuracy.
- Beadwork holds durable progress/blockers. Report blocked checks honestly; do not weaken assertions or silently waive gates. Final approval does not authorize unrequested commits/pushes/merges.
- Test exclusions and command side effects that can mislead validation: `mem:suggested_commands`.
