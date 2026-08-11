# 🚦 Hajime

[![Tests](https://github.com/mtzaquia/hajime/actions/workflows/tests.yml/badge.svg)](https://github.com/mtzaquia/hajime/actions/workflows/tests.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](Package.swift)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](Package.swift)

`Hajime` is a Swift app-boot orchestration library built around an explicit
readiness graph.

Declare the work an app needs before it can serve users, express dependencies in
source order, and let one application-owned `Bootstrap` coordinate readiness.

- Express startup dependencies as named sequential steps.
- Start independent work together inside explicit `Parallel` groups.
- Release readiness immediately or after a budget while selected work continues.
- Suspend deep links and other consumers until the active run is ready.
- Bridge delegate callbacks and profile the complete boot without ad hoc tasks.

```swift
import Hajime

let boot = Bootstrap {
  Parallel {
    BootStep("restore-session") {
      try await session.restore()
    }
    BootStep("load-configuration") {
      try await configuration.load()
    }
  }

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

Create and retain a `Bootstrap` at the application composition root:

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
    BootStep("load-configuration") {
      try await configuration.load()
    }
  }

  BootStep("warm-cache", priority: .utility) {
    try await cache.warm()
  }
  .nonBlocking(after: .milliseconds(300))

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}

boot.start()

func handleDeepLink(_ url: URL) async throws {
  try await boot.waitUntilReady()
  await router.open(url)
}
```

Declarations at the same level run sequentially. `Parallel` starts its direct
children together. The cache step gets 300 milliseconds to finish before it
stops delaying readiness; the same work continues afterward.

`waitUntilReady()` supports callers that arrive before `start()` and multiple
concurrent consumers. A readiness-blocking failure skips later sequential work
and resumes every waiter with that error. Calling `start()` again replaces the
active run while existing readiness waiters follow the replacement.

That is the core idea: the plan defines what readiness means, and consumers
suspend on that shared contract instead of reconstructing boot state.

## Documentation

- [Boot plans](docs/boot-plans.md) — compose sequential and parallel work, reuse
  subplans, select priorities, and understand failure propagation.
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

Open [`SampleApp/SampleApp.xcworkspace`](SampleApp/SampleApp.xcworkspace) and run
the **SampleApp** scheme. The deterministic boot lab makes sequential work,
parallel overlap, readiness release, observed lifecycle state, and performance
measurements visible in one timeline.

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
