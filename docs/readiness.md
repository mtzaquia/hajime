# Readiness

`Bootstrap` owns one application boot pipe. It starts the immutable plan,
publishes an observable lifecycle snapshot and a current-value stream, and
suspends consumers until the current execution succeeds.

## Start application boot

Keep the coordinator in application-owned state and start it from the
composition root:

```swift
import Hajime

let boot = Bootstrap {
  BootStep("restore-session") {
    try await session.restore()
  }

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}

boot.start()
```

`start()` returns after scheduling the plan. Calling it again requests
cancellation of the current run and schedules its replacement. The replacement
readiness chain begins after the superseded readiness chain finishes, so those
chains never overlap. Step cancellation remains cooperative; a blocking step
that ignores cancellation can delay its replacement.

Signals declared through `BootStep.waiting(for:)` are part of that execution
pipe. Replacement cancels their old waiters and rearms the same instances with
fresh first-resolution-wins storage before the new plan begins. This lets a
failed callback-backed step retry without rebuilding the signals bag or
rewiring delegates.

Outstanding steps that released readiness through `nonBlocking()` or
`nonBlocking(after:)` receive cancellation immediately. Hajime does not wait
for them before starting the replacement readiness chain, so a step that does
not promptly observe or finish after cancellation may briefly overlap its
replacement.

## Suspend readiness-dependent work

Use `waitUntilReady()` for deep links and other work that cannot proceed during
cold boot:

```swift
func handleDeepLink(_ url: URL) async throws {
  try await boot.waitUntilReady()
  await router.open(url)
}
```

The call may begin before `start()` and any number of consumers may wait
concurrently. They return together after the current plan succeeds. If the plan
fails or is explicitly cancelled, they throw the same terminal outcome.

When `start()` replaces a running execution, existing waiters remain suspended
for the replacement. This keeps a cold-boot deep link attached to application
readiness instead of exposing an internal restart as cancellation.

Cancelling one task suspended in `waitUntilReady()` cancels only that wait. It
does not cancel application boot.

## Inspect the current state

`state` distinguishes the coordinator's lifecycle:

```swift
switch boot.state {
case .idle:
  // start() has not been called
case .booting:
  // the current plan is running
case .ready:
  // readiness-dependent work may proceed
case .failed(let failure):
  // failure.error is the error thrown by the step
case .cancelled:
  // the current execution ended with cancellation
}
```

`isReady` is shorthand for `state == .ready`. Both properties are synchronous,
concurrency-safe snapshots intended for presentation and diagnostics. `State`
equality compares lifecycle phases, so two `.failed` values compare equal even
when their retained errors differ. Pattern-match `.failed(let failure)` when
the error matters.

`failure.error` is the original `Error`, which is `Sendable` in Swift 6. Map
app-owned errors to user-facing copy explicitly. `failure.errorType` contains
only the concrete type name and is suitable when privacy-safe metadata is
enough; Hajime never derives a description or associated values for you.

`Bootstrap` conforms to the Observation framework, so SwiftUI invalidates a
view that reads either property when the lifecycle changes:

```swift
import Hajime
import SwiftUI

struct AppRoot: View {
  let boot: Bootstrap

  var body: some View {
    Group {
      switch boot.state {
      case .idle, .booting:
        ProgressView("Starting…")
      case .ready:
        AppContent()
      case .failed(let failure):
        BootFailureView(error: failure.error, retry: boot.start)
      case .cancelled:
        BootCancelledView(retry: boot.start)
      }
    }
    .task {
      if boot.state == .idle {
        boot.start()
      }
    }
  }
}
```

Keep the `Bootstrap` at the application composition root and pass the same
instance into the view hierarchy. No app-owned `@State` mirror, view model, or
SwiftUI-specific Hajime adapter is required. Hajime imports Observation for
change tracking but does not depend on SwiftUI or require main-actor ownership.

## Observe state asynchronously

Use `stateUpdates` when a non-UI consumer needs lifecycle updates:

```swift
for await state in boot.stateUpdates {
  bootTelemetry.record(state)
}
```

Each property access creates an independent subscription and immediately emits
one state captured atomically with registration. Starting, completing, failing,
cancelling, or replacing an execution then emits its lifecycle transition. A
replacement requested while already booting emits `.booting` again because it
represents a new execution even though the snapshot value is unchanged.

State transitions are semantic events, so each active subscription retains its
unconsumed transitions in order. A slow subscriber therefore receives every
replacement and terminal state rather than silently coalescing them. Cancel
subscriptions that no longer have a consumer. Releasing the `Bootstrap`
publishes cancellation when needed, finishes every stream, and does not require
subscribers to retain the coordinator.

Iterate a separate `stateUpdates` value in each task. Cancelling one subscriber
removes only that subscription and does not cancel boot or other subscribers.

These observation APIs can change after a later `start()`. Use
`waitUntilReady()` instead of polling, stream iteration, or check-then-act
control flow when subsequent work requires readiness.

## Own or cancel the full run

Use `run()` when one task owns the complete boot lifetime:

```swift
try await boot.run()
```

It starts the pipe and waits for readiness. Cancelling the calling task cancels
the shared execution. By contrast, cancelling a standalone
`waitUntilReady()` caller leaves boot running.

Call `cancel()` to explicitly end the current execution and resume all waiters
with `CancellationError`. After readiness, `cancel()` preserves the ready state
while still requesting cancellation of outstanding non-blocking steps. A
later `start()` begins a fresh run. Releasing the application-owned `Bootstrap`
also requests cancellation of its current readiness chain and outstanding
steps.

Next: [Boot progress](progress.md) · [Non-blocking work](non-blocking-work.md) ·
[Signals](signals.md) · [Diagnostics](diagnostics.md)
