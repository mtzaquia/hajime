# 🚦 Hajime

[![Tests](https://github.com/mtzaquia/hajime/actions/workflows/tests.yml/badge.svg)](https://github.com/mtzaquia/hajime/actions/workflows/tests.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](Package.swift)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](Package.swift)

`Hajime` is a Swift app-boot orchestration library built around an explicit
readiness graph.

Declare named asynchronous steps in the order they should run. Group independent
readiness work in `Parallel`, apply a readiness policy to individual steps,
then execute the immutable plan from one bootstrap runner.

- Keep sequential startup dependencies legible in source order.
- Begin independent operations concurrently inside explicit parallel groups.
- Let selected steps continue without delaying application readiness.
- Give slow steps a budget before they stop delaying readiness.
- Extract reusable subplans without changing their ordering.
- Request an execution priority for each step, defaulting to `.userInitiated`.
- Suspend work until the current boot execution reports readiness.
- Render SwiftUI directly from the observed boot lifecycle.
- Bridge synchronous delegate callbacks into asynchronous boot steps.
- Profile every boot boundary in Instruments or forward completed intervals.
- Propagate readiness-blocking failures and stop later sequential work.
- Preserve the actor isolation of each asynchronous operation.

```swift
import Hajime

let boot = Bootstrap("app-launch") {
  BootStep("configure-foundation") {
    configureFoundation()
  }

  Parallel {
    BootStep("restore-session") {
      try await session.restore()
    }
    BootStep("load-feature-flags") {
      try await featureFlags.load()
    }
  }

  BootStep("warm-cache", priority: .utility) {
    try await cache.warm()
  }
  .nonBlocking()

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}

boot.start()
try await boot.waitUntilReady()
```

## Install

Hajime requires Swift 6.3 and supports iOS 17+ and macOS 14+. Add it with Swift
Package Manager:

```swift
dependencies: [
  .package(
    url: "https://github.com/mtzaquia/hajime.git",
    from: "1.0.0"
  ),
]
```

Then add the `Hajime` product to your target dependencies:

```swift
.target(
  name: "YourApp",
  dependencies: [
    .product(name: "Hajime", package: "Hajime"),
  ]
)
```

## Five-minute start

Create a `Bootstrap` at the application composition root. Declarations at the
same level run sequentially, while direct children of `Parallel` begin
concurrently:

```swift
import Hajime

func makeBootstrap(
  session: SessionService,
  configuration: ConfigurationService,
  router: Router
) -> Bootstrap {
  Bootstrap {
    Parallel {
      BootStep("restore-session") {
        try await session.restore()
      }
      BootStep("load-configuration") {
        try await configuration.load()
      }
    }

    BootStep("warm-cache", priority: .utility) {
      try await configuration.warmCache()
    }
    .nonBlocking(after: .milliseconds(300))

    BootStep("prepare-routing") {
      try await router.prepare()
    }
  }
}
```

Keep the `Bootstrap` as application-owned state, start its single execution
pipe, and suspend consumers that require readiness:

```swift
let boot = makeBootstrap(
  session: session,
  configuration: configuration,
  router: router
)

boot.start()

func handleDeepLink(_ url: URL) async throws {
  try await boot.waitUntilReady()
  await router.open(url)
}
```

`waitUntilReady()` may be called before `start()` and by multiple consumers. If
one operation throws, Hajime skips later sequential declarations and resumes
all readiness waiters with that error. A parallel failure also requests
cancellation of unfinished siblings.

Calling `start()` again cancels and replaces the current run. Existing waiters
remain attached to the pipe and wait for the replacement. `isReady` and `state`
provide synchronous observable snapshots for presentation and diagnostics. A
SwiftUI view can read them directly without copying lifecycle state into local
`@State`:

```swift
import Hajime
import SwiftUI

struct AppRoot: View {
  let boot: Bootstrap

  var body: some View {
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
}
```

Hajime uses the Observation framework but does not depend on SwiftUI. The
failure retains the original error for app-owned presentation and exposes
`errorType` when only privacy-safe type metadata is appropriate. Hajime never
turns the error into a description on the application's behalf.

For non-UI observation, each access to `stateUpdates` creates an independent
current-value stream of the same states. Use `waitUntilReady()` for coordination
rather than polling or treating presentation observation as a readiness gate.

Every bootstrap emits low-overhead Instruments signposts by default in debug
and release builds. Add one synchronous callback when the same completed
intervals should feed an observability system:

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

The callback receives the run identifier, execution attempt, scope, start
offset, duration, and outcome. It should enqueue in constant time. Use
`.disabled` for processes where neither signposts nor measurements are wanted.

That is the core idea: declaration order expresses dependencies, and
`Parallel` marks readiness work that can safely overlap. A step's
`nonBlocking` modifier changes only how long that complete step contributes to
readiness.

Use `.nonBlocking()` to release readiness immediately, or
`.nonBlocking(after:)` to let the step block until a budget expires. Budget
expiry is a one-way transition, not a timeout: the same task keeps running and
its later failure is contained. The policy covers the operation plus every
signal wait and handler. Modifier order is immaterial, so
`.waiting(for: signal).nonBlocking(after: duration)` and the reverse spelling
behave identically.

## Step priority

`BootStep` defaults to `.userInitiated` because most boot declarations block
immediate app use. Override it when an operation can tolerate less urgency:

```swift
BootStep("warm-disk-cache", priority: .utility) {
  try await cache.warm()
}
.nonBlocking(after: .milliseconds(300))
```

Priority is an execution hint, not an ordering mechanism. Source order and
`Parallel` continue to define execution order. Neither `nonBlocking()` nor
`nonBlocking(after:)` changes a step's requested priority, and Swift may raise
a step's effective priority when higher-priority work awaits it.

## Delegate bridges

Use an app-owned signals bag to connect delegate callbacks to boot steps. Both
sides share the same signal; the delegate fulfills it synchronously without
creating a `Task`:

```swift
import Hajime
import UIKit

struct AppBootSignals: Sendable {
  let pushRegistration = BootSignal<Data>("push-registration")
  let attestation = BootSignal<Data>("app-attestation")
}

let appBoot = AppBootSignals()
appDelegate.pushRegistration = appBoot.pushRegistration

let boot = Bootstrap {
  BootStep("register-push-notifications") { @MainActor in
    UIApplication.shared.registerForRemoteNotifications()
  }
  .waiting(for: appBoot.pushRegistration) { token in
    try await server.send(token)
  }
}

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
```

The step finishes only after registration succeeds and `server.send(_:)`
returns. Signal or handler failure fails the step. The modifier also registers
the signal with this `Bootstrap`, so starting the same coordinator again rearms
the same signal instance for the replacement run.

Chain modifiers when independent callbacks and handlers may overlap:

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

Both waits begin concurrently, and the step finishes after both handlers. Use
one grouped modifier when a handler needs two or three values together. A
standalone `BootSignal` is an instance-lifetime one-shot bridge. Declaration
through `.waiting(for:)` gives it one first-wins resolution per run of its
owning bootstrap.

## Documentation

- [Readiness](docs/readiness.md) — start, replace, await, observe, and cancel the
  application boot pipe, including direct SwiftUI rendering.
- [Non-blocking work](docs/non-blocking-work.md) — let individual steps outlive
  readiness immediately or after a budget.
- [Signals](docs/signals.md) — bridge delegate and service callbacks into boot
  steps, combine requirements, and rearm them safely for retries.
- [Performance instrumentation](docs/instrumentation.md) — profile release
  boots and forward one privacy-conscious stream of completed intervals.
- [Diagnostics](docs/diagnostics.md) — inspect correlated lifecycle events and
  their privacy contract.

## Sample app

Open [`SampleApp/SampleApp.xcworkspace`](SampleApp/SampleApp.xcworkspace) and run the
**SampleApp** scheme to inspect a deterministic boot timeline. The lab shows a
sequential foundation step, two overlapping service steps, a cache warmup that
continues after readiness, and a final routing step, with controls to run and
reset the plan.

## License

Copyright (c) 2026 @mtzaquia

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
