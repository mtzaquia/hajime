# 🚦 Hajime

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](Package.swift)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](Package.swift)

`Hajime` is a Swift app-boot orchestration library built around an explicit
sequence-and-parallel plan.

Declare named asynchronous steps in the order they should run. Group independent
work in `Parallel`, then execute the immutable plan from one bootstrap runner.

- Keep sequential startup dependencies legible in source order.
- Begin independent operations concurrently inside explicit parallel groups.
- Extract reusable subplans without changing their ordering.
- Propagate thrown failures and stop later sequential work.
- Preserve the actor isolation of each asynchronous operation.

```swift
import Hajime

let bootstrap = Bootstrap {
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

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}

try await bootstrap.run()
```

## Install

Hajime currently requires Swift 6.3 and supports iOS 17+ and macOS 14+. It is
under active development and does not have a tagged release yet. Add this
checkout as a local Swift package while the initial API is being shaped.

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

    BootStep("prepare-routing") {
      try await router.prepare()
    }
  }
}
```

Call `run()` from the app-owned startup task. It returns after the complete plan
succeeds. If one operation throws, Hajime skips later sequential declarations;
a parallel failure also requests cancellation of unfinished siblings.

```swift
try await makeBootstrap(
  session: session,
  configuration: configuration,
  router: router
).run()
```

Each call starts a new execution. Readiness, single-flight execution, blocking
budgets, non-blocking failures, preview behavior, and delegate-driven signals
are intentionally outside this first scaffold.

That is the core idea: declaration order expresses dependencies, and
`Parallel` marks the work that can safely overlap.

## Sample app

Open [`SampleApp/SampleApp.xcworkspace`](SampleApp/SampleApp.xcworkspace) and run the
**SampleApp** scheme to inspect a deterministic boot timeline. The lab shows a
sequential foundation step, two overlapping service steps, and a final routing
step, with controls to run and reset the plan.

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
