# Performance instrumentation

Hajime measures the orchestration boundaries it already owns. A bootstrap emits
Instruments signposts automatically, while one optional callback can forward the
same completed intervals to the telemetry system used by an application.

## Profile a release boot

Give each coordinator a stable name and profile the app with Instruments:

```swift
let boot = Bootstrap("app-launch") {
  BootStep("restore-session") {
    try await session.restore()
  }

  BootStep("register-push") {
    registerForPush()
  }
  .waiting(for: signals.pushRegistration) { token in
    try await server.send(token)
  }
}
```

No instrumentation declarations belong inside the plan. Hajime emits
`OSSignposter` intervals under subsystem `eu.lelfe.hajime` and category
`Performance` in both debug and release builds. Start an Instruments recording
before launch to capture the complete request-to-readiness interval.

The push step appears as distinct nested work:

```text
register-push
├─ operation
├─ wait: push-registration
└─ handler: push-registration
```

This separates time spent initiating a delegate-driven API from time spent
waiting for its callback and processing the result. Chained requirements emit
independent, potentially overlapping waits and handlers. A grouped requirement
emits one wait per signal followed by one handler for the complete group.

## Forward completed intervals

Use `BootInstrumentation.measurements(_:)` when another observability system
should receive the same model:

```swift
let boot = Bootstrap(
  "app-launch",
  instrumentation: .measurements { measurement in
    bootTelemetry.enqueue(measurement)
  }
) {
  appBootPlan
}
```

Hajime invokes the callback synchronously on whichever task completes an
interval. `bootTelemetry` must therefore be safe to call concurrently and
should enqueue or record in constant time. Do not perform network, disk, actor,
or other suspending work directly in the callback. Hajime does not create a
`Task` for each measurement.

The callback adds to the automatic Instruments signposts. Use
`instrumentation: .disabled` to disable both paths for a coordinator.

## Interpret a measurement

Every `BootInstrumentation.Measurement` contains:

| Field | Meaning |
| --- | --- |
| `bootstrap` | The stable developer-authored coordinator name. |
| `runID` | An opaque identifier shared by every interval from one execution. |
| `attempt` | The one-based execution number. Every `start()` or `run()` increments it. |
| `scope` | The orchestration boundary that completed. |
| `startOffset` | Its start relative to the matching `start()` request. |
| `duration` | Time elapsed within that boundary. |
| `outcome` | Success, cancellation, readiness release, or failure with only a concrete error type. |

The available scopes are:

| Scope | Interval |
| --- | --- |
| `.bootstrap` | From the synchronous `start()` request through readiness, failure, or cancellation. |
| `.scheduling` | From that request until the replacement has cleared and plan execution can begin. |
| `.step` | A complete step, including its operation and all signal requirements. |
| `.operation` | Only the closure passed to `BootStep`. |
| `.signalWait` | One signal suspension, including buffered immediate resolution. |
| `.signalHandler` | The handler invoked after one or more signals succeed. |
| `.parallel` | A group from child launch until every child finishes or releases readiness. |
| `.readinessBudget` | From step start until it finishes, is cancelled, or releases readiness at its budget. |
| `.nonBlocking` | The remainder of one step after it stops delaying readiness. |

Non-blocking intervals may arrive after the `.bootstrap` interval because that
work deliberately continues beyond readiness. Their step name and `runID`
attribute them to the execution that launched them. A budget that expires ends
with `.releasedReadiness`; the complete `.step` and subsequent `.nonBlocking`
interval later report the work's eventual outcome.

## Preserve privacy and timing quality

Bootstrap, step, and signal names are public instrumentation metadata. Use
stable identifiers such as `"app-launch"`, `"restore-session"`, and
`"push-registration"`; never derive them from user data or runtime values.

Measurements and signposts include no signal values, tokens, payloads, URLs,
error descriptions, or localized descriptions. A failure contains only its
concrete error type.

`Hajime.debug` is a separate, debug-only lifecycle facility. Leave it off while
collecting representative boot timings because log construction and console
I/O can perturb the result. Performance instrumentation is available in release
builds without enabling debug logging.

Next: [Readiness](readiness.md) · [Signals](signals.md) ·
[Diagnostics](diagnostics.md)
