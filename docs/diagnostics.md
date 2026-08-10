# Diagnostics

Hajime provides opt-in lifecycle logging for inspecting a boot plan without
changing its execution. Diagnostics are off by default and are compiled out of
non-debug Hajime builds.

Enable logging once at the application composition root:

```swift
#if DEBUG
Hajime.debug = .normal
#endif
```

`Hajime.debug` is process-wide and safe to read or update from concurrent
tasks.

## Levels

| Level | Events |
| --- | --- |
| `.off` | Nothing. This is the default. |
| `.normal` | Boot, step, readiness-release, and signal waits, completions, cancellations, and failures. |
| `.trace` | Everything in `.normal`, plus parallel boundaries, signal arming and rearming, buffered-result replay, and duplicate resolution. |

Use `.normal` for routine boot investigation. Use `.trace` when the shape or
overlap of the plan matters.

## Reading the output

One successful run can look like this:

```text
[boot][A1B2C3D4] → started | steps=4 parallel_groups=1 non_blocking_steps=1
[signal][A1B2C3D4] → armed | signal="push-registration"
[step][A1B2C3D4] → started | step="restore-session" priority=user_initiated
[step][A1B2C3D4] ✓ completed | step="restore-session"
[parallel][A1B2C3D4] → started | children=2
[signal][A1B2C3D4] ⏳ waiting | signal="push-registration"
[signal] ✓ succeeded | signal="push-registration"
[parallel][A1B2C3D4] ✓ completed | children=2
[step][A1B2C3D4] → started | step="warm-cache" priority=utility
[step][A1B2C3D4] ↗ released readiness | step="warm-cache" after=0.300s
[boot][A1B2C3D4] ✓ completed
[step][A1B2C3D4] ✓ completed | step="warm-cache"
```

The eight-character identifier correlates events from one boot execution. It is
inherited by sequential and parallel step tasks and is unique to that
execution. A replacement started through `Bootstrap.start()` receives a new
identifier.

A readiness-release event names the affected step and reports either
`after=immediate` or its configured budget. The step's later completion,
cancellation, or failure keeps the same run identifier, so post-readiness work
remains attributable to the execution that launched it.

## Diagnose delegate bridges

The same signal instance connects the boot step and delegate:

```swift
let appBoot = AppBootSignals()
appDelegate.pushRegistration = appBoot.pushRegistration

BootStep("register-push-notifications") {
  UIApplication.shared.registerForRemoteNotifications()
}
.waiting(for: appBoot.pushRegistration) { token in
  try await server.send(token)
}

func application(
  _ application: UIApplication,
  didRegisterForRemoteNotificationsWithDeviceToken token: Data
) {
  pushRegistration.succeed(token)
}
```

The wait event normally inherits the boot trace identifier. A delegate callback
may run outside that task-local context, so its resolution event can appear
without the identifier; the stable signal name connects the two events.

Normal diagnostics report waits, first resolution, waiter cancellation, and
failure. Trace diagnostics additionally report per-run arming, stored-result
replay, and ignored duplicate resolution. Late fulfillment after cancellation
is safe; a replacement run emits a rearming event before executing its plan.

Waiting on a signal that was not declared through `.waiting(for:)`, or attaching
one signal to two bootstraps, emits an actionable warning even when
`Hajime.debug` is `.off` and even in release builds. These warnings contain only
the stable developer-authored signal name. The corresponding
`BootSignalError` fails the affected boot execution instead of leaving it
suspended.

Hajime uses the unified logging subsystem `eu.lelfe.hajime` and category
`Hajime`.

Lifecycle logging is separate from performance instrumentation. Bootstrap
signposts use category `Performance` and are available in release builds;
see [Performance instrumentation](instrumentation.md). Leave debug logging off
when collecting representative timings because console output can perturb the
measurement.

## Privacy contract

Diagnostics report only orchestration metadata:

- the developer-authored step name;
- the developer-authored signal name;
- step and parallel-group counts;
- the count of steps configured with a non-blocking readiness policy;
- the requested task priority;
- the concrete error type when an operation fails.

They never inspect or log values captured by a step, values carried by a
`BootSignal`, tokens, URLs, payloads, user data, an error's description, or an
error's localized description.

Step and signal names are public log text. Use stable identifiers such as
`"restore-session"` and `"push-registration"`; do not construct them from
runtime or sensitive values.

## Release builds

When Hajime is compiled without `DEBUG`, optional diagnostic calls and message
construction are omitted. Assigning `Hajime.debug` produces no lifecycle logs.
Actionable signal-configuration warnings stay enabled.
