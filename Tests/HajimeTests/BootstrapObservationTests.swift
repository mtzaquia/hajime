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

import Observation
import os
import Testing
@testable import Hajime

private actor ObservedBootProbe {
    private var startCount = 0
    private var cancellationCount = 0
    private var isReleased = false

    func hold() async throws {
        startCount += 1

        do {
            while !isReleased {
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func waitForStarts(_ count: Int) async {
        while startCount < count {
            await Task.yield()
        }
    }

    func waitForCancellations(_ count: Int) async {
        while cancellationCount < count {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

private actor FailOnceProbe {
    private var shouldFail = true

    func run() throws {
        guard shouldFail else { return }
        shouldFail = false
        throw ObservedBootFailure.expected(code: 17)
    }
}

private final class ObservedReferenceFailure: Error, Sendable {}

private actor ReferenceFailureProbe {
    private var failure: ObservedReferenceFailure?

    init(failure: ObservedReferenceFailure) {
        self.failure = failure
    }

    func run() throws {
        guard let failure else { return }
        self.failure = nil
        throw failure
    }
}

private enum ObservedBootFailure: Error, Equatable {
    case expected(code: Int)
}

@Suite("Bootstrap observation")
struct BootstrapObservationTests {
    @Test("Observation tracks start and ready transitions")
    func invalidatesTrackedState() async throws {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        let started = OSAllocatedUnfairLock(initialState: false)
        let alsoStarted = OSAllocatedUnfairLock(initialState: false)

        _ = withObservationTracking {
            bootstrap.state
        } onChange: {
            started.withLock { $0 = true }
        }
        _ = withObservationTracking {
            bootstrap.isReady
        } onChange: {
            alsoStarted.withLock { $0 = true }
        }

        bootstrap.start()
        await probe.waitForStarts(1)

        #expect(started.withLock { $0 })
        #expect(alsoStarted.withLock { $0 })
        #expect(bootstrap.state == .booting)

        let completed = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking {
            bootstrap.state
        } onChange: {
            completed.withLock { $0 = true }
        }

        await probe.release()
        try await bootstrap.waitUntilReady()

        #expect(completed.withLock { $0 })
        #expect(bootstrap.state == .ready)
        guard case .ready = bootstrap.state else {
            Issue.record("Expected a ready state")
            return
        }
    }

    @Test("A lifecycle stream starts with a coherent snapshot")
    func emitsInitialStartAndReadyStates() async throws {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        var states = bootstrap.stateUpdates.makeAsyncIterator()

        #expect(await states.next() == .idle)

        bootstrap.start()
        #expect(await states.next() == .booting)

        await probe.release()
        try await bootstrap.waitUntilReady()
        #expect(await states.next() == .ready)

        var readyStates = bootstrap.stateUpdates.makeAsyncIterator()
        #expect(await readyStates.next() == .ready)
    }

    @Test("A failure reaches observation, the stream, and every waiter")
    func propagatesFailureEverywhere() async {
        let signal = BootSignal<Void>("release-failure")
        let bootstrap = Bootstrap {
            BootStep("failing") {}
                .waiting(for: signal) {
                    throw ObservedBootFailure.expected(code: 17)
                }
        }
        var states = bootstrap.stateUpdates.makeAsyncIterator()
        #expect(await states.next() == .idle)

        bootstrap.start()
        #expect(await states.next() == .booting)
        while signal.pendingWaiterCount == 0 {
            await Task.yield()
        }

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking {
            bootstrap.state
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        let firstWaiter = Task {
            try await bootstrap.waitUntilReady()
        }
        let secondWaiter = Task {
            try await bootstrap.waitUntilReady()
        }

        signal.succeed()

        await #expect(throws: ObservedBootFailure.self) {
            try await firstWaiter.value
        }
        await #expect(throws: ObservedBootFailure.self) {
            try await secondWaiter.value
        }
        #expect(invalidated.withLock { $0 })
        guard case .failed = bootstrap.state else {
            Issue.record("Expected a failed state")
            return
        }

        guard let state = await states.next(),
              case .failed(let streamedFailure) = state else {
            Issue.record("Expected a streamed failure")
            return
        }
        assertExpectedFailure(streamedFailure)

        guard case .failed(let observedFailure) = bootstrap.state else {
            Issue.record("Expected an observable failure")
            return
        }
        assertExpectedFailure(observedFailure)

        var lateStates = bootstrap.stateUpdates.makeAsyncIterator()
        guard let lateState = await lateStates.next(),
              case .failed(let lateFailure) = lateState else {
            Issue.record("Expected a coherent late failure snapshot")
            return
        }
        assertExpectedFailure(lateFailure)
    }

    @Test("Restart clears a failure and can become ready")
    func replacesFailureOnRestart() async throws {
        let probe = FailOnceProbe()
        let bootstrap = Bootstrap {
            BootStep("fail-once") {
                try await probe.run()
            }
        }
        var states = bootstrap.stateUpdates.makeAsyncIterator()
        #expect(await states.next() == .idle)

        bootstrap.start()
        await #expect(throws: ObservedBootFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        #expect(await states.next() == .booting)
        guard let failed = await states.next(), case .failed = failed else {
            Issue.record("Expected the first execution to fail")
            return
        }

        bootstrap.start()
        #expect(await states.next() == .booting)
        try await bootstrap.waitUntilReady()
        #expect(await states.next() == .ready)
        #expect(bootstrap.state == .ready)
    }

    @Test("Failure payloads do not change state equality")
    func comparesFailureStatesByPhase() {
        let first = Bootstrap.State.failed(
            Bootstrap.Failure(ObservedBootFailure.expected(code: 17))
        )
        let second = Bootstrap.State.failed(
            Bootstrap.Failure(ObservedBootFailure.expected(code: 42))
        )

        #expect(first == second)
        #expect(first != .ready)
    }

    @Test("Explicit cancellation reaches the lifecycle and waiters")
    func emitsCancellation() async {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        var states = bootstrap.stateUpdates.makeAsyncIterator()
        #expect(await states.next() == .idle)

        bootstrap.start()
        #expect(await states.next() == .booting)
        await probe.waitForStarts(1)
        let waiter = Task {
            try await bootstrap.waitUntilReady()
        }
        bootstrap.cancel()

        #expect(await states.next() == .cancelled)
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        guard case .cancelled = bootstrap.state else {
            Issue.record("Expected a cancelled state")
            return
        }
    }

    @Test("A slow subscriber receives every replacement transition")
    func retainsSemanticTransitionsUntilConsumed() async throws {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        let updates = bootstrap.stateUpdates

        bootstrap.start()
        await probe.waitForStarts(1)
        bootstrap.start()
        await probe.waitForCancellations(1)
        await probe.waitForStarts(2)
        await probe.release()
        try await bootstrap.waitUntilReady()

        var states = updates.makeAsyncIterator()
        #expect(await states.next() == .idle)
        #expect(await states.next() == .booting)
        #expect(await states.next() == .booting)
        #expect(await states.next() == .ready)
    }

    @Test("Multiple lifecycle subscribers receive the same transitions")
    func broadcastsToMultipleSubscribers() async throws {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        var first = bootstrap.stateUpdates.makeAsyncIterator()
        var second = bootstrap.stateUpdates.makeAsyncIterator()

        #expect(await first.next() == .idle)
        #expect(await second.next() == .idle)

        bootstrap.start()
        #expect(await first.next() == .booting)
        #expect(await second.next() == .booting)

        await probe.release()
        try await bootstrap.waitUntilReady()
        #expect(await first.next() == .ready)
        #expect(await second.next() == .ready)
    }

    @Test("Cancelling one subscriber leaves boot running")
    func removesCancelledSubscriber() async throws {
        let probe = ObservedBootProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        let subscriber = Task {
            for await _ in bootstrap.stateUpdates {}
        }

        await waitForSubscribers(1, on: bootstrap)
        bootstrap.start()
        await probe.waitForStarts(1)
        subscriber.cancel()
        await subscriber.value
        await waitForSubscribers(0, on: bootstrap)

        #expect(bootstrap.state == .booting)
        await probe.release()
        try await bootstrap.waitUntilReady()
    }

    @Test("A lifecycle stream does not retain its bootstrap")
    func finishesWithCancellationOnBootstrapRelease() async {
        var bootstrap: Bootstrap? = Bootstrap {
            BootStep("complete") {}
        }
        weak let weakBootstrap = bootstrap
        var states = bootstrap!.stateUpdates.makeAsyncIterator()

        #expect(await states.next() == .idle)
        bootstrap = nil

        #expect(weakBootstrap == nil)
        #expect(await states.next() == .cancelled)
        #expect(await states.next() == nil)
    }

    @Test("A retained failure is released by the next execution")
    func releasesFailureOnRestart() async throws {
        var failure: ObservedReferenceFailure? = ObservedReferenceFailure()
        weak let weakFailure = failure
        let probe = ReferenceFailureProbe(failure: failure!)
        let bootstrap = Bootstrap {
            BootStep("fail-once") {
                try await probe.run()
            }
        }
        failure = nil

        bootstrap.start()
        await #expect(throws: ObservedReferenceFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        #expect(weakFailure != nil)

        bootstrap.start()
        try await bootstrap.waitUntilReady()
        while weakFailure != nil {
            await Task.yield()
        }

        #expect(weakFailure == nil)
    }

    @Test("Discarding a lifecycle stream removes its subscription")
    func discardsUnusedSubscription() {
        let bootstrap = Bootstrap {
            BootStep("complete") {}
        }

        #expect(makeAndDiscardStateUpdates(from: bootstrap) == 1)
        #expect(bootstrap.stateUpdateSubscriberCount == 0)
    }

    private func assertExpectedFailure(_ failure: Bootstrap.Failure) {
        #expect(failure.errorType == "ObservedBootFailure")
        #expect(
            failure.error as? ObservedBootFailure == .expected(code: 17)
        )
    }

    private func waitForSubscribers(
        _ count: Int,
        on bootstrap: Bootstrap
    ) async {
        while bootstrap.stateUpdateSubscriberCount != count {
            await Task.yield()
        }
    }

    private func makeAndDiscardStateUpdates(
        from bootstrap: Bootstrap
    ) -> Int {
        let updates = bootstrap.stateUpdates
        let subscriberCount = bootstrap.stateUpdateSubscriberCount
        withExtendedLifetime(updates) {}
        return subscriberCount
    }
}
