# Hajime Sample App

Open `SampleApp.xcworkspace` and run the **SampleApp** scheme on an iOS 17 or
later simulator. The workspace links `SampleAppPackage` to the parent Hajime
checkout, so edits to `Sources/Hajime` are available immediately.

The app is a focused orchestration lab for the initial DSL:

- **Run the boot plan** executes a foundation step, two service steps inside
  `Parallel`, and a final routing step through the real `Bootstrap` API.
- **Inspect execution** presents start and completion events with elapsed times,
  making sequential ordering and the overlap between parallel operations
  visible without relying on console output.
- **Reset** cancels an active run or clears a completed trace so the same
  deterministic plan can be replayed.

The library's package tests are the authoritative proof of ordering, overlap,
composition, control flow, and failure propagation. The sample has no UI-test
target because SwiftUI is only a display surface for those logic contracts.
