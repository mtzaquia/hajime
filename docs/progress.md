# Observe boot progress

`Bootstrap.progress` emits the execution phases of individual boot steps. Use
it when a loading screen, developer tool, or timeline needs more detail than the
overall lifecycle exposed by `state` and `stateUpdates`.

## Follow the latest step

Each value identifies one occurrence of a `BootStep`, the bootstrap attempt
that reached it, and its latest phase:

```swift
for await step in boot.progress {
  bootScreen.show(
    title: localizedTitle(for: step.name),
    phase: step.phase
  )
}
```

Hajime emits `.running` when it commits to executing a step. A step that stops
delaying application readiness while its work remains active then emits
`.continuing`. Every reached step finally emits `.succeeded`, `.failed`, or
`.cancelled`. Cancellation remains cooperative; `.cancelled` means Hajime no
longer treats the step as active for that attempt, even if its operation takes
additional time to return.

`name` is the stable developer-authored diagnostic name supplied to `BootStep`.
Map it to localized presentation rather than displaying it as user-facing copy.

## Build a local list

The same step ID is emitted as that step changes phase. Keep the latest value
for each ID when a screen needs to render several sequential or parallel steps:

```swift
@State private var attempt: UInt64?
@State private var steps: [BootProgress] = []

var body: some View {
  List(steps) { step in
    BootStepRow(
      title: localizedTitle(for: step.name),
      phase: step.phase
    )
  }
  .task {
    for await step in boot.progress {
      if attempt != step.attempt {
        attempt = step.attempt
        steps.removeAll()
      }

      if let index = steps.firstIndex(where: { $0.id == step.id }) {
        steps[index] = step
      } else {
        steps.append(step)
      }
    }
  }
}
```

IDs remain stable across attempts of one `Bootstrap`, including when the same
diagnostic name appears more than once. `attempt` increments whenever `start()`
begins a replacement execution, allowing presentation to reset without
reconstructing the bootstrap or its plan.

## Understand subscription behavior

Each access to `progress` creates an independent subscription. A subscriber
joining after execution has begun first receives the latest phase of every step
already reached in the current attempt, ordered by when each step first began.
It then receives every later phase transition. Steps not yet reached do not
emit placeholder values.

Progress transitions are semantic events, so active subscriptions retain
unconsumed values in order. Cancel a subscription when its consumer disappears.
Cancelling iteration removes only that subscriber and does not cancel boot.
Releasing the `Bootstrap` emits cancellation for active steps and finishes all
progress streams.

The stream is nonthrowing. A step failure appears as
`BootProgress.Phase.failed`, carrying the same retained `Bootstrap.Failure`
available from the overall failed state. Use `waitUntilReady()` when subsequent
work must suspend for readiness and receive the original error through `throw`.

## Choose the right observation API

- `state` is the observable current lifecycle snapshot for presentation.
- `stateUpdates` streams overall lifecycle transitions to asynchronous
  observers.
- `progress` streams the phases of individual reached steps.
- `waitUntilReady()` coordinates work that cannot proceed before readiness.
- `BootInstrumentation` records completed timing intervals for profiling and
  telemetry.

Next: [Readiness](readiness.md) · [Non-blocking work](non-blocking-work.md) ·
[Performance instrumentation](instrumentation.md)
