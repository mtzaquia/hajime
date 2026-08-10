# Signals

`BootSignal` bridges a callback from a delegate or service into asynchronous
boot work. One app-owned signal is shared by the producer and all consumers;
the boot DSL declares when that signal extends step readiness and rearms it for
replacement runs.

## Own signals as app state

Group signals in an app-specific value whose properties express the callbacks
your boot plan expects:

```swift
import Hajime

struct AppBootSignals: Sendable {
  let pushRegistration = BootSignal<Data>("push-registration")
  let attestation = BootSignal<Data>("app-attestation")
  let migrationFinished = BootSignal<Void>("migration-finished")
}

let appBoot = AppBootSignals()
```

The bag is application code rather than a Hajime registry. This preserves
static types, makes ownership visible, and avoids string-based lookup.

Signal names are developer-authored diagnostic identifiers. Keep them stable
and never derive them from tokens, user data, URLs, payloads, or other runtime
values.

## Connect a delegate callback

Assign the same signal instance to the callback owner:

```swift
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  var pushRegistration: BootSignal<Data>!

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    pushRegistration.succeed(deviceToken)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: any Error
  ) {
    pushRegistration.fail(error)
  }
}

appDelegate.pushRegistration = appBoot.pushRegistration
```

`succeed(_:)` and `fail(_:)` are synchronous and concurrency-safe, so delegate
methods do not need to create a `Task`. The callback value is never inspected
or logged by Hajime.

Use `resolve(_:)` when a service already produces a `Result`:

```swift
appBoot.pushRegistration.resolve(registrationResult)
```

For a `BootSignal<Void>`, call `succeed()` after the callback completes.

## Extend a step through the callback

Attach the signal to the step that initiates the system work:

```swift
let boot = Bootstrap {
  BootStep("register-push-notifications") { @MainActor in
    UIApplication.shared.registerForRemoteNotifications()
  }
  .waiting(for: appBoot.pushRegistration) { token in
    try await server.send(token)
  }
}
```

The operation initiates registration and returns. Hajime then waits for the
signal, invokes the handler with its value, and marks the step complete only
after the handler returns. A signal failure skips the handler and fails the
step; an error thrown by the handler also fails the step.

When a callback may take too long to hold app readiness, apply a readiness
budget to that same step:

```swift
BootStep("register-push-notifications") {
  registerForPush()
}
.waiting(for: appBoot.pushRegistration) { token in
  try await server.send(token)
}
.nonBlocking(after: .seconds(2))
```

The operation, signal wait, and handler remain one step. If they exceed two
seconds, the step keeps running but no longer delays readiness. Applying
`.nonBlocking(after:)` before or after `.waiting(for:)` is equivalent.

The modifier supports both callback orderings:

- If fulfillment happens first, the result is buffered and returned
  immediately when the requirement begins waiting.
- If waiting happens first, the delegate callback resumes the requirement.

Use `.waiting(for:)` without a handler when only completion matters:

```swift
BootStep("run-migration") {
  migration.start()
}
.waiting(for: appBoot.migrationFinished)
```

## Wait for several callbacks

Chained requirements begin waiting concurrently. Each handler runs as soon as
its own signal succeeds, and the step finishes after every handler returns:

```swift
BootStep("register-system-services") {
  registerForPush()
  requestAttestation()
}
.waiting(for: appBoot.pushRegistration) { token in
  try await server.send(token)
}
.waiting(for: appBoot.attestation) { assertion in
  try await server.send(assertion)
}
```

The first signal or handler failure cancels the other outstanding requirement
and fails the step. A handler that already completed may have produced side
effects before another requirement fails.

When one operation needs the values together, group two or three signals in one
requirement:

```swift
BootStep("register-system-services") {
  registerForPush()
  requestAttestation()
}
.waiting(
  for: appBoot.pushRegistration,
  appBoot.attestation
) { token, assertion in
  try await server.register(
    pushToken: token,
    attestation: assertion
  )
}
```

The grouped handler runs once after every supplied signal succeeds.

## Retry with the same signal instances

Declaring a signal through `.waiting(for:)` registers it with that `Bootstrap`.
The signal keeps one first-wins result for each execution. Calling `start()` or
`run()` again cancels outstanding waits from the superseded execution, discards
its stored result, and rearms the same signal instance before the replacement
plan begins:

```swift
do {
  try await boot.run()
} catch {
  try await boot.run()
}
```

A result delivered before the first run is adopted by that run. After a run has
started, duplicate and late resolutions remain harmless. Because synchronous
delegate callbacks do not carry a Hajime run identifier, a callback arriving
after a replacement has been armed resolves that active run. Producers whose
attempts can genuinely overlap need their own request identifier.

A managed signal belongs to one `Bootstrap` for its lifetime. Reusing it in
another coordinator fails with
`BootSignalError.registeredToAnotherBootstrap(signal:)`.

## Wait directly

Use `wait()` for additional consumers:

```swift
let token = try await appBoot.pushRegistration.wait()
```

Within a bootstrap execution, the signal must already be declared by a
`.waiting(for:)` requirement somewhere in that plan. Forgetting the declaration
throws `BootSignalError.notRegistered(signal:)` immediately and fails boot
instead of hanging or replaying unrelated state.

Outside bootstrap execution, an unmanaged signal behaves as a standalone
one-shot bridge. Its first success or failure is buffered for every current and
future waiter. A direct waiter on a managed signal observes its currently active
run.

The first success or failure in each lifetime wins. Duplicate fulfillment is
harmless and does not replace the stored result.

## Handle cancellation

Cancelling one task suspended in `wait()` removes and resumes only that waiter
with `CancellationError`. Other waiters in the same lifetime remain attached,
and a later callback can still fulfill an unresolved signal.

Cancelling or replacing a bootstrap run cancels its managed signal waits. Late
delegate fulfillment remains safe and never traps; a retry rearms the signal
with fresh storage.

Next: [Readiness](readiness.md) · [Diagnostics](diagnostics.md)
