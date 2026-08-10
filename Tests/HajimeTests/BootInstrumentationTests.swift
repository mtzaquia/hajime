//
//  Copyright (c) 2026 @mtzaquia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import os
import Testing
@testable import Hajime

private final class MeasurementRecorder: Sendable {
    typealias Measurement = BootInstrumentation.Measurement

    private let lock = OSAllocatedUnfairLock(initialState: [Measurement]())

    var measurements: [Measurement] {
        lock.withLock { $0 }
    }

    func record(_ measurement: Measurement) {
        lock.withLock { $0.append(measurement) }
    }

    func waitFor(
        _ predicate: @escaping @Sendable ([Measurement]) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while !lock.withLock({ predicate($0) }) {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

private enum InstrumentationFailure: Error {
    case sensitive(String)
}

private actor InstrumentationCancellationProbe {
    private var started = false

    func hold() async throws {
        started = true
        try await Task.sleep(for: .seconds(10))
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor InstrumentationReplacementProbe {
    private var executionCount = 0
    private var firstStarted = false
    private var mayFinishFirst = false

    func execute() async {
        executionCount += 1
        guard executionCount == 1 else { return }

        firstStarted = true
        while !mayFinishFirst {
            await Task.yield()
        }
    }

    func waitUntilFirstStarted() async {
        while !firstStarted {
            await Task.yield()
        }
    }

    func finishFirst() {
        mayFinishFirst = true
    }
}

@Suite("Boot instrumentation")
struct BootInstrumentationTests {
    @Test("A successful run emits every orchestration boundary")
    func emitsCanonicalSuccessfulIntervals() async throws {
        let recorder = MeasurementRecorder()
        let pushSignal = BootSignal<String>("push-registration")
        let bootstrap = Bootstrap(
            "app-launch",
            instrumentation: .measurements(recorder.record)
        ) {
            Parallel {
                BootStep("configuration") {}
                BootStep("register-push") {
                    pushSignal.succeed("private-token")
                }
                .waiting(for: pushSignal) { _ in }
            }

            BootStep("warm-cache", priority: .utility) {}
                .nonBlocking()
        }

        try await bootstrap.run()
        let receivedStep = await recorder.waitFor { measurements in
            measurements.contains {
                $0.scope == .nonBlocking(step: "warm-cache")
            }
        }
        #expect(receivedStep)

        let measurements = recorder.measurements
        let runIDs = Set(measurements.map(\.runID))
        #expect(runIDs.count == 1)
        #expect(measurements.allSatisfy { $0.bootstrap == "app-launch" })
        #expect(measurements.allSatisfy { $0.attempt == 1 })
        #expect(measurements.allSatisfy { $0.startOffset >= .zero })
        #expect(measurements.allSatisfy { $0.duration >= .zero })
        #expect(measurements.allSatisfy { $0.outcome == .succeeded })

        #expect(measurements.count(where: { $0.scope == .bootstrap }) == 1)
        #expect(measurements.count(where: { $0.scope == .scheduling }) == 1)
        #expect(measurements.count(where: { $0.scope == .parallel }) == 1)
        #expect(measurements.count(where: {
            $0.scope == .nonBlocking(step: "warm-cache")
        }) == 1)
        #expect(measurements.count(where: { measurement in
            if case .step = measurement.scope { return true }
            return false
        }) == 3)
        #expect(measurements.count(where: { measurement in
            if case .operation = measurement.scope { return true }
            return false
        }) == 3)
        #expect(measurements.contains { measurement in
            measurement.scope == .signalWait(
                signal: "push-registration",
                step: "register-push"
            )
        })
        #expect(measurements.contains { measurement in
            measurement.scope == .signalHandler(
                signals: ["push-registration"],
                step: "register-push"
            )
        })
    }

    @Test("A readiness budget separates release from eventual completion")
    func measuresReadinessDemotion() async throws {
        let recorder = MeasurementRecorder()
        let signal = BootSignal<Void>("cache-restored")
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("restore-cache") {}
                .waiting(for: signal)
                .nonBlocking(after: .milliseconds(5))
        }

        bootstrap.start()
        while signal.pendingWaiterCount == 0 {
            await Task.yield()
        }
        try await bootstrap.waitUntilReady()

        let budget = try #require(
            recorder.measurements.first {
                $0.scope == .readinessBudget(step: "restore-cache")
            }
        )
        #expect(budget.outcome == .releasedReadiness)
        #expect(!recorder.measurements.contains {
            $0.scope == .step(
                name: "restore-cache",
                priority: .userInitiated
            )
        })

        signal.succeed()
        let completed = await recorder.waitFor { measurements in
            measurements.contains {
                $0.scope == .nonBlocking(step: "restore-cache")
                    && $0.outcome == .succeeded
            }
        }
        #expect(completed)
        #expect(recorder.measurements.contains {
            $0.scope == .step(
                name: "restore-cache",
                priority: .userInitiated
            ) && $0.outcome == .succeeded
        })
    }

    @Test("Retries receive a new run identifier and consecutive attempt")
    func identifiesRetryAttempts() async throws {
        let recorder = MeasurementRecorder()
        let bootstrap = Bootstrap(
            "app-launch",
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("configuration") {}
        }

        try await bootstrap.run()
        try await bootstrap.run()

        let boots = recorder.measurements.filter { $0.scope == .bootstrap }
        #expect(boots.map(\.attempt) == [1, 2])
        #expect(Set(boots.map(\.runID)).count == 2)
    }

    @Test("Scheduling includes cooperative replacement delay")
    func measuresReplacementScheduling() async throws {
        let recorder = MeasurementRecorder()
        let probe = InstrumentationReplacementProbe()
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("configuration") {
                await probe.execute()
            }
        }

        bootstrap.start()
        await probe.waitUntilFirstStarted()
        bootstrap.start()
        try await Task.sleep(for: .milliseconds(10))
        await probe.finishFirst()
        try await bootstrap.waitUntilReady()

        let secondScheduling = try #require(
            recorder.measurements.first {
                $0.attempt == 2 && $0.scope == .scheduling
            }
        )
        #expect(secondScheduling.duration >= .milliseconds(5))
        #expect(secondScheduling.outcome == .succeeded)

        let firstBoot = try #require(
            recorder.measurements.first {
                $0.attempt == 1 && $0.scope == .bootstrap
            }
        )
        #expect(firstBoot.outcome == .cancelled)
    }

    @Test("Grouped requirements emit one wait per signal and one handler")
    func separatesGroupedSignalIntervals() async throws {
        let recorder = MeasurementRecorder()
        let token = BootSignal<String>("push-registration")
        let permission = BootSignal<Bool>("notification-permission")
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("register-push") {
                token.succeed("private-token")
                permission.succeed(true)
            }
            .waiting(for: token, permission) { _, _ in }
        }

        try await bootstrap.run()

        let waits = recorder.measurements.compactMap { measurement in
            if case .signalWait(let signal, _) = measurement.scope {
                return signal
            }
            return nil
        }
        #expect(Set(waits) == [
            "push-registration",
            "notification-permission",
        ])

        let handlers = recorder.measurements.filter { measurement in
            if case .signalHandler = measurement.scope { return true }
            return false
        }
        #expect(handlers.count == 1)
        #expect(handlers[0].scope == .signalHandler(
            signals: ["push-registration", "notification-permission"],
            step: "register-push"
        ))
    }

    @Test("An idle cancellation does not consume an attempt")
    func countsExecutionsRatherThanCoordinatorGenerations() async throws {
        let recorder = MeasurementRecorder()
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("configuration") {}
        }

        bootstrap.cancel()
        try await bootstrap.run()

        let boot = try #require(
            recorder.measurements.first { $0.scope == .bootstrap }
        )
        #expect(boot.attempt == 1)
    }

    @Test("Failures expose only the concrete error type")
    func redactsFailureDetails() async {
        let recorder = MeasurementRecorder()
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("secrets") {
                throw InstrumentationFailure.sensitive("do-not-record")
            }
        }

        await #expect(throws: InstrumentationFailure.self) {
            try await bootstrap.run()
        }

        let failures = recorder.measurements.compactMap { measurement in
            if case .failed(let errorType) = measurement.outcome {
                return errorType
            }
            return nil
        }
        #expect(failures.count == 3)
        #expect(failures.allSatisfy {
            $0.contains("InstrumentationFailure")
                && !$0.contains("do-not-record")
        })
    }

    @Test("Cancellation is classified consistently at every active boundary")
    func classifiesCancellation() async {
        let recorder = MeasurementRecorder()
        let probe = InstrumentationCancellationProbe()
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("configuration") {
                try await probe.hold()
            }
        }

        bootstrap.start()
        await probe.waitUntilStarted()
        bootstrap.cancel()

        await #expect(throws: CancellationError.self) {
            try await bootstrap.waitUntilReady()
        }
        let receivedRoot = await recorder.waitFor { measurements in
            measurements.contains { $0.scope == .bootstrap }
        }
        #expect(receivedRoot)

        let cancelledScopes: [BootInstrumentation.Measurement.Scope] =
            recorder.measurements.compactMap { measurement in
                guard measurement.outcome == .cancelled else { return nil }
                return measurement.scope
            }
        #expect(cancelledScopes.contains(.bootstrap))
        #expect(cancelledScopes.contains(.step(
            name: "configuration",
            priority: .userInitiated
        )))
        #expect(cancelledScopes.contains(.operation(step: "configuration")))
    }

    @Test("The root measurement is delivered before readiness returns")
    func deliversRootSynchronously() async throws {
        let recorder = MeasurementRecorder()
        let bootstrap = Bootstrap(
            instrumentation: .measurements(recorder.record)
        ) {
            BootStep("configuration") {}
        }

        try await bootstrap.run()

        #expect(recorder.measurements.contains { $0.scope == .bootstrap })
    }
}
