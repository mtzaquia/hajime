# Readiness

`Bootstrap` owns one application boot pipe. It starts the immutable plan,
publishes a synchronous lifecycle snapshot, and suspends consumers until the
current execution succeeds.

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
case .failed:
  // a step threw a non-cancellation error
case .cancelled:
  // the current execution ended with cancellation
}
```

`isReady` is shorthand for `state == .ready`. Both properties are synchronous,
concurrency-safe snapshots intended for presentation and diagnostics. They can
change after a later `start()`, so use `waitUntilReady()` instead of polling or
check-then-act control flow.

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

Next: [Non-blocking work](non-blocking-work.md) · [Signals](signals.md) ·
[Diagnostics](diagnostics.md)
