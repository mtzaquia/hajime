# Non-blocking work

`BootStep` can stop contributing to application readiness while its work keeps
running. The modifier applies to the complete step: its operation, signal waits,
and signal handlers remain one step with one requested priority and one eventual
outcome.

## Release readiness immediately

Use `nonBlocking()` for work that should begin at a known point in the plan but
never hold the app's readiness gate:

```swift
import Hajime

let boot = Bootstrap {
  BootStep("restore-session") {
    try await session.restore()
  }

  BootStep("warm-cache", priority: .utility) {
    try await cache.warm()
  }
  .nonBlocking()

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}

try await boot.run()
```

Hajime starts `warm-cache`, immediately continues to `prepare-routing`, and
marks the bootstrap ready when the remaining readiness chain succeeds. The
cache step remains owned and instrumented by that bootstrap until it finishes.

`nonBlocking()` does not imply `.background` priority. The example requests
`.utility` explicitly; an omitted priority still uses `BootStep`'s
`.userInitiated` default.

## Give a slow step a readiness budget

Use `nonBlocking(after:)` when the preferred outcome is to finish before
readiness, while an unusually slow execution should continue afterward:

```swift
BootStep("restore-content") {
  try await content.restore()
}
.nonBlocking(after: .milliseconds(300))
```

If the complete step succeeds within 300 milliseconds, the surrounding plan
waits for it exactly like an ordinary step. If it is still active at the
budget, Hajime releases readiness and lets the same task continue. The
transition does not cancel, restart, duplicate, or reprioritize any work. A
zero or negative duration is equivalent to `nonBlocking()`.

This is a readiness budget, not a timeout. Hajime does not throw a timeout
error, and it does not terminate the operation when the budget expires.

## Include delegate-backed completion

Signal requirements are part of the same step and therefore share its
readiness policy:

```swift
BootStep("register-push") {
  registerForPush()
}
.waiting(for: signals.pushRegistration) { token in
  try await server.send(token)
}
.nonBlocking(after: .seconds(2))
```

Registration, the delegate callback wait, and `server.send(_:)` all have the
same two-second readiness budget. The step finishes only after the handler
returns, even if readiness was released earlier.

Modifiers describe independent parts of a `BootStep` value. Applying them in
either order is equivalent:

```swift
step.waiting(for: signal).nonBlocking(after: .seconds(2))
step.nonBlocking(after: .seconds(2)).waiting(for: signal)
```

Chained and grouped signal requirements behave the same way: every requirement
must finish before the step itself finishes.

## Understand outcomes and cancellation

Before a readiness budget expires, an error fails boot normally. After a step
has released readiness, a later error is contained: it is reported by
diagnostics and performance instrumentation but cannot fail the surrounding
readiness chain or revoke a ready state.

Calling `cancel()`, starting a replacement, or releasing the `Bootstrap`
requests cancellation of all unfinished non-blocking steps. Hajime does not
wait for those steps before starting replacement readiness work, so code that
does not promptly observe cooperative cancellation can briefly overlap its
replacement.

The same overlap consideration applies to a managed `BootSignal`. Replacement
rearms the signal for its new run. Use a callback-backed non-blocking step only
when cancellation prevents the old producer from delivering afterward, or when
the producer carries its own request identifier.

Next: [Readiness](readiness.md) · [Performance instrumentation](instrumentation.md) ·
[Diagnostics](diagnostics.md)
