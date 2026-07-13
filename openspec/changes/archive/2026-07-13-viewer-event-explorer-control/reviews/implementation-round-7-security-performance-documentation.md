# Security, Performance, and Documentation Implementation Review — Round 7

## SPD-R7-001 — P1 High: renderer and composer result deliveries are untracked

Confidence: 10/10

Renderer and composer completion bridges bypass the cancellation/delivery ownership now used by
store operations, so MainActor tasks and content-bearing results are neither structurally bounded nor
joined by cleanup.

- `ViewerRendererPreparationService` tracks only its queue worker. Replacement/cancel callbacks are
  invoked synchronously, and an executed result invokes client completion before the worker tracker
  completes.
- `ViewerEventExplorerController.submitRenderer` unconditionally creates an untracked
  `Task { @MainActor ... }`. `sealAndClear` waits for renderer service work, coordinator work, and
  store-operation work, but not this delivery task. Service cleanup may therefore finish after merely
  enqueueing a derived renderer result and before MainActor handles or discards it.
- Composer has the same gap: its service tracker owns only the worker, while
  `ViewerControlComposerController` completion creates an untracked MainActor task. Superseding or
  cancelling requests can enqueue request-proportional tasks despite the service retaining at most two
  requests. A successful task can retain a prepared Event/content until MainActor execution.

This contradicts the Event Explorer update/privacy requirement, lifecycle design, task 6.7,
operator documentation, and blocked-cleanup evidence, which claim every completion uses a bounded
cancellation/delivery handoff and cleanup joins result application. Existing service-level tests use
synchronous collectors and do not exercise either controller bridge. The round-6 controller stress
tests cover store-operation delivery only.

Impact: repeated selection/send/supersession while MainActor or a preparation queue is stalled can
create work proportional to requests outside the advertised bound. Renderer-derived values or a
successfully prepared composer Event can remain captured after the finite cleanup receipt reports
completion. Sealed/generation checks prevent common stale state application but do not bound, cancel,
join, or release those tasks before receipt completion.

Required remediation:

- Give renderer generation and composer attempt the same atomic delivery gate and exact work-tracker
  ownership used by store callbacks.
- A callback must claim before creating a MainActor task. Cancellation that wins must drop without a
  task and retire ownership; a claimed delivery must keep ownership until MainActor handles/discards
  and releases the result.
- Include bridge work in cleanup and pending counts.
- Add controller-level tests for 100,000 blocked renderer replacements and composer
  send/cancel/supersede cycles with constant retained work and zero cancelled delivery tasks.
- Add a successful content-bearing result paused immediately after delivery claim, proving cleanup
  remains pending until MainActor discard and all content/task counts reach zero.

Independent validation passed strict OpenSpec, Swift format, diff hygiene, plist/project/package
inspection, and three adjacent tests. No new scripts, shell phases, remote packages, Core/SDK runtime
dependencies, clipboard/log/preferences leakage, or file-export path regression was found.
Configured signing and embedded-entitlement verification remains deferred and is not a finding.

**Unresolved findings: 1**
