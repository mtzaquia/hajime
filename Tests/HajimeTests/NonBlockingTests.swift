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

import Testing
@testable import Hajime

private actor StepTrace {
    private(set) var events: [String] = []
    private(set) var executionCount = 0
    private(set) var cancellationCount = 0
    private var isReleased = false

    func append(_ event: String) {
        events.append(event)
    }

    func hold(_ name: String) async throws {
        executionCount += 1
        events.append("\(name)-started")

        do {
            let deadline = TestDeadline("!isReleased")
            while !isReleased {
                try deadline.check()
                try await Task.sleep(for: .milliseconds(1))
            }
            events.append("\(name)-finished")
        } catch is CancellationError {
            cancellationCount += 1
            events.append("\(name)-cancelled")
            throw CancellationError()
        }
    }

    func waitForEvent(_ event: String) async throws {
        let deadline = TestDeadline("!events.contains(event)")
        while !events.contains(event) {
            try deadline.check()
            await Task.yield()
        }
    }

    func waitForCancellation() async throws {
        let deadline = TestDeadline("cancellationCount == 0")
        while cancellationCount == 0 {
            try deadline.check()
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

private actor StepPriorityProbe {
    private var priority: TaskPriority?
    private var hasStarted = false
    private var isReleased = false

    func holdAndRecordPriority() async throws {
        hasStarted = true
        let deadline = TestDeadline("!isReleased")
        while !isReleased {
            try deadline.check()
            await Task.yield()
        }

        let priority = Task.currentPriority
        self.priority = priority
    }

    func waitUntilStarted() async throws {
        let deadline = TestDeadline("!hasStarted")
        while !hasStarted {
            try deadline.check()
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }

    func waitForPriority() async throws -> TaskPriority {
        let deadline = TestDeadline("priority == nil")
        while priority == nil {
            try deadline.check()
            await Task.yield()
        }
        return try #require(priority)
    }
}

private actor ReplacementStepProbe {
    private var executionCount = 0
    private var expectedStartCount = 0
    private var activeCount = 0
    private var releaseFirstExecution = false
    private(set) var maximumActiveCount = 0
    private(set) var observedCancellation = false

    func execute() async throws {
        executionCount += 1
        let execution = executionCount
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }

        guard execution == 1 else { return }
        let deadline = TestDeadline("!releaseFirstExecution")
        while !releaseFirstExecution {
            try deadline.check()
            if Task.isCancelled {
                observedCancellation = true
            }
            await Task.yield()
        }
    }

    func waitForCurrentExecution() async throws {
        expectedStartCount += 1
        let count = expectedStartCount
        let deadline = TestDeadline("executionCount < count")
        while executionCount < count {
            try deadline.check()
            await Task.yield()
        }
    }

    func releaseFirst() {
        releaseFirstExecution = true
    }

    func waitUntilInactive() async throws {
        let deadline = TestDeadline("activeCount > 0")
        while activeCount > 0 {
            try deadline.check()
            await Task.yield()
        }
    }
}

private enum NonBlockingFailure: Error {
    case expected
}

private enum ModifierOrder: CaseIterable {
    case waitingFirst
    case readinessFirst
}

@Suite("Non-blocking boot steps")
struct NonBlockingTests {
    @Test("An immediate non-blocking step releases readiness and keeps running")
    func immediatelyReleasesReadiness() async throws {
        let trace = StepTrace()
        let bootstrap = Bootstrap {
            BootStep("warm-cache") {
                try await trace.hold("warm-cache")
            }
            .nonBlocking()

            BootStep("prepare-routing") {
                try await trace.waitForEvent("warm-cache-started")
                await trace.append("ready-chain-finished")
            }
        }

        try await bootstrap.run()

        #expect(bootstrap.isReady)
        #expect(await trace.events == [
            "warm-cache-started",
            "ready-chain-finished",
        ])
        #expect(bootstrap.hasOutstandingNonBlockingSteps)

        await trace.release()
        try await waitForNonBlockingStepsToFinish(on: bootstrap)
        #expect(await trace.executionCount == 1)
        #expect(await trace.events.last == "warm-cache-finished")
    }

    @Test("A late failure is contained after immediate readiness release")
    func containsImmediateFailure() async throws {
        let signal = BootSignal<Void>("release-failure")
        let bootstrap = Bootstrap {
            BootStep("eventually-fails") {}
                .waiting(for: signal) { _ in
                    throw NonBlockingFailure.expected
                }
                .nonBlocking()
        }

        try await bootstrap.run()
        #expect(bootstrap.state == .ready)

        signal.succeed()
        try await waitForNonBlockingStepsToFinish(on: bootstrap)
        #expect(bootstrap.state == .ready)
    }

    @Test("Post-readiness observation preserves the step priority")
    func preservesStepPriority() async throws {
        let probe = StepPriorityProbe()
        let bootstrap = Bootstrap {
            BootStep("warm-cache", priority: .utility) {
                try await probe.holdAndRecordPriority()
            }
            .nonBlocking()
        }

        bootstrap.start()
        try await probe.waitUntilStarted()
        try await bootstrap.waitUntilReady()
        for _ in 0..<10 {
            await Task.yield()
        }
        await probe.release()
        let priority = try await probe.waitForPriority()
        try await waitForNonBlockingStepsToFinish(on: bootstrap)

        #expect(priority == .utility)
    }

    @Test("Completion before the budget behaves like a blocking step")
    func completesBeforeBudget() async throws {
        let trace = StepTrace()
        let bootstrap = Bootstrap {
            BootStep("configuration") {
                await trace.append("configuration")
            }
            .nonBlocking(after: .seconds(1))

            BootStep("routing") {
                await trace.append("routing")
            }
        }

        try await bootstrap.run()

        #expect(await trace.events == ["configuration", "routing"])
        #expect(!bootstrap.hasOutstandingNonBlockingSteps)
    }

    @Test("Failure before the budget still fails boot")
    func propagatesFailureBeforeBudget() async throws {
        let bootstrap = Bootstrap {
            BootStep("configuration") {
                throw NonBlockingFailure.expected
            }
            .nonBlocking(after: .seconds(1))
        }

        await #expect(throws: NonBlockingFailure.self) {
            try await bootstrap.run()
        }
        guard case .failed = bootstrap.state else {
            Issue.record("Expected boot to fail")
            return
        }
    }

    @Test("Budget expiry releases readiness without restarting the step")
    func demotesOneRunningStep() async throws {
        let trace = StepTrace()
        let bootstrap = Bootstrap {
            BootStep("restore-content") {
                try await trace.hold("restore-content")
            }
            .nonBlocking(after: .milliseconds(5))

            BootStep("routing") {
                await trace.append("routing")
            }
        }

        try await bootstrap.run()

        #expect(bootstrap.isReady)
        #expect(await trace.executionCount == 1)
        #expect(await trace.events == ["restore-content-started", "routing"])

        await trace.release()
        try await waitForNonBlockingStepsToFinish(on: bootstrap)
        #expect(await trace.executionCount == 1)
        #expect(await trace.events.last == "restore-content-finished")
    }

    @Test("Failure after budget expiry does not revoke readiness")
    func containsFailureAfterBudget() async throws {
        let signal = BootSignal<Void>("release-failure")
        let bootstrap = Bootstrap {
            BootStep("eventually-fails") {}
                .waiting(for: signal) { _ in
                    throw NonBlockingFailure.expected
                }
                .nonBlocking(after: .milliseconds(5))
        }

        try await bootstrap.run()
        #expect(bootstrap.state == .ready)

        signal.succeed()
        try await waitForNonBlockingStepsToFinish(on: bootstrap)
        #expect(bootstrap.state == .ready)
    }

    @Test("Non-positive budgets normalize to immediate non-blocking readiness")
    func normalizesNonPositiveBudgets() {
        let zero = BootStep("zero") {}.nonBlocking(after: .zero)
        let negative = BootStep("negative") {}
            .nonBlocking(after: .milliseconds(-1))

        #expect(zero.readiness == .nonBlocking)
        #expect(negative.readiness == .nonBlocking)
    }

    @Test("Modifier order is equivalent when a signal wins the budget")
    func modifierOrderBeforeBudget() async throws {
        var results: [[String]] = []

        for order in ModifierOrder.allCases {
            let signal = BootSignal<Int>("push-registration-\(order)")
            let trace = StepTrace()
            let step = configuredStep(
                signal: signal,
                order: order,
                duration: .seconds(1),
                trace: trace
            )
            let bootstrap = Bootstrap { step }

            bootstrap.start()
            try await waitForWaiters(1, on: signal)
            #expect(bootstrap.state == .booting)
            signal.succeed(42)
            try await bootstrap.waitUntilReady()
            results.append(await trace.events)
        }

        #expect(results == [
            ["operation", "handler-42"],
            ["operation", "handler-42"],
        ])
    }

    @Test("Modifier order is equivalent when the budget wins a signal")
    func modifierOrderAfterBudget() async throws {
        var results: [[String]] = []

        for order in ModifierOrder.allCases {
            let signal = BootSignal<Int>("push-registration-\(order)")
            let trace = StepTrace()
            let step = configuredStep(
                signal: signal,
                order: order,
                duration: .milliseconds(5),
                trace: trace
            )
            let bootstrap = Bootstrap { step }

            bootstrap.start()
            try await waitForWaiters(1, on: signal)
            try await bootstrap.waitUntilReady()
            #expect(await trace.events == ["operation"])

            signal.succeed(42)
            try await trace.waitForEvent("handler-42")
            try await waitForNonBlockingStepsToFinish(on: bootstrap)
            results.append(await trace.events)
        }

        #expect(results == [
            ["operation", "handler-42"],
            ["operation", "handler-42"],
        ])
    }

    @Test("Cancelling after readiness cancels an outstanding signal wait")
    func cancelsOutstandingWait() async throws {
        let signal = BootSignal<Void>("push-registration")
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .nonBlocking(after: .milliseconds(5))
                .waiting(for: signal)
        }

        bootstrap.start()
        try await waitForWaiters(1, on: signal)
        try await bootstrap.waitUntilReady()
        bootstrap.cancel()

        try await waitForWaiters(0, on: signal)
        try await waitForNonBlockingStepsToFinish(on: bootstrap)
        #expect(bootstrap.state == .ready)
    }

    @Test("Releasing Bootstrap cancels its outstanding step")
    func cancellationFollowsBootstrapOwnership() async throws {
        let trace = StepTrace()
        var bootstrap: Bootstrap? = Bootstrap {
            BootStep("warm-cache") {
                try await trace.hold("warm-cache")
            }
            .nonBlocking()
        }

        try await bootstrap?.run()
        bootstrap = nil
        try await trace.waitForCancellation()

        #expect(await trace.events.contains("warm-cache-cancelled"))
    }

    @Test("Slow cancellation does not delay replacement readiness")
    func replacesWithoutWaitingForStepCancellation() async throws {
        let probe = ReplacementStepProbe()
        let bootstrap = Bootstrap {
            BootStep("warm-cache") {
                try await probe.execute()
            }
            .nonBlocking()

            BootStep("routing") {
                try await probe.waitForCurrentExecution()
            }
        }

        try await bootstrap.run()
        bootstrap.start()
        try await bootstrap.waitUntilReady()

        #expect(bootstrap.isReady)
        #expect(await probe.observedCancellation)
        #expect(await probe.maximumActiveCount == 2)

        await probe.releaseFirst()
        try await probe.waitUntilInactive()
    }

    private func configuredStep(
        signal: BootSignal<Int>,
        order: ModifierOrder,
        duration: Duration,
        trace: StepTrace
    ) -> BootStep {
        let step = BootStep("register-push") {
            await trace.append("operation")
        }

        switch order {
        case .waitingFirst:
            return step
                .waiting(for: signal) { value in
                    await trace.append("handler-\(value)")
                }
                .nonBlocking(after: duration)
        case .readinessFirst:
            return step
                .nonBlocking(after: duration)
                .waiting(for: signal) { value in
                    await trace.append("handler-\(value)")
                }
        }
    }

    private func waitForWaiters<Value: Sendable>(
        _ count: Int,
        on signal: BootSignal<Value>
    ) async throws {
        let deadline = TestDeadline("signal.pendingWaiterCount != count")
        while signal.pendingWaiterCount != count {
            try deadline.check()
            await Task.yield()
        }
    }

    private func waitForNonBlockingStepsToFinish(
        on bootstrap: Bootstrap
    ) async throws {
        let deadline = TestDeadline("bootstrap.hasOutstandingNonBlockingSteps")
        while bootstrap.hasOutstandingNonBlockingSteps {
            try deadline.check()
            await Task.yield()
        }
    }
}
