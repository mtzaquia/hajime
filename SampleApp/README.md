# Hajime Sample App

Open `SampleApp.xcworkspace` and run the **SampleApp** scheme on an iOS 17 or
later simulator. The workspace links `SampleAppPackage` to the parent Hajime
checkout, so edits to `Sources/Hajime` are available immediately.

The app is a focused orchestration lab for Hajime's boot DSL:

- **Start and await readiness** uses one application-owned `Bootstrap`, calls
  `start()`, and awaits `waitUntilReady()` while a foundation step, two service
  steps inside `Parallel`, a utility-priority cache warmup that releases
  readiness after 0.3 seconds, and a final routing step execute.
- **Inspect execution** presents start and completion events with elapsed times,
  making sequential ordering, explicit parallel overlap, readiness, and the
  still-running non-blocking step visible without relying on console output.
- **Inspect performance** renders Hajime's real `BootInstrumentation`
  measurements for the same run, including scheduling, step, operation,
  parallel, readiness-budget, post-readiness, and complete
  request-to-readiness intervals.
- `Hajime.debug = .trace` is enabled so the Xcode console also shows correlated
  boot, step, parallel-group, and readiness-release lifecycle events.
- **Reset** explicitly cancels the coordinator or clears a completed trace. A
  replay calls `start()` on the same coordinator and replaces its prior run.

All timings are deterministic, so each run makes sequential ordering, parallel
overlap, readiness release, and post-readiness completion directly observable.
