# Boot plans

`BootPlan` describes startup dependencies as an immutable sequence of named
asynchronous operations. Source order defines sequencing, `Parallel` identifies
work that may overlap, and extracted plans preserve their internal structure.

## Express ordering

Declarations at the same level run sequentially. A `Parallel` group starts each
direct child concurrently and waits until every child either succeeds or
releases readiness:

```swift
import Hajime

let foundation = BootPlan {
  BootStep("configure-database") {
    try await database.configure()
  }

  BootStep("restore-session") {
    try await session.restore()
  }
}

let boot = Bootstrap("app-launch") {
  foundation

  Parallel {
    BootStep("load-configuration") {
      try await configuration.load()
    }

    BootStep("prepare-search") {
      try await search.prepare()
    }
  }

  BootStep("prepare-routing") {
    try await router.prepare()
  }
}
```

The extracted `foundation` plan remains sequential. Embedding a plan inside
`Parallel` treats that sequence as one child, so its steps remain ordered while
other children run beside it.

## Use builder control flow

The plan builder supports conditions, availability checks, and loops. These are
evaluated when the plan is created:

```swift
let plan = BootPlan {
  if account.isSignedIn {
    BootStep("restore-account") {
      try await account.restore()
    }
  }

  for feature in enabledFeatures {
    BootStep("prepare-\(feature.diagnosticName)") {
      try await feature.prepare()
    }
  }
}
```

Step names are public diagnostic and instrumentation metadata. Keep them stable
and do not derive them from user data or other sensitive runtime values.

## Select a task priority

`BootStep` requests `.userInitiated` priority by default because ordinary boot
work delays immediate app use. Choose another priority when the operation can
tolerate less urgency:

```swift
BootStep("warm-disk-cache", priority: .utility) {
  try await cache.warm()
}
.nonBlocking(after: .milliseconds(300))
```

Priority is an execution hint, not an ordering mechanism. Source order and
`Parallel` define ordering, and neither `nonBlocking()` nor
`nonBlocking(after:)` changes the requested priority. Swift may raise effective
priority when higher-priority work awaits the step.

## Preserve isolation and propagate failures

A step closure can inherit actor isolation from its declaration:

```swift
BootStep("configure-appearance") { @MainActor in
  appearance.configure()
}
```

When a readiness-blocking step throws, Hajime skips later declarations in that
sequence. A failure inside `Parallel` also requests cancellation of unfinished
siblings before propagating the error. Cancellation remains cooperative, so
operations must observe it when prompt teardown matters.

Failures that occur after a step releases readiness are contained instead. See
[Non-blocking work](non-blocking-work.md) for that boundary.

Next: [Readiness](readiness.md) · [Non-blocking work](non-blocking-work.md)
