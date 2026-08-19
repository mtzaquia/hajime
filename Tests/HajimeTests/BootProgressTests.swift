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

private actor ProgressProbe {
    private var startCount = 0
    private var cancellationCount = 0
    private var mayFinish = false

    func hold() async throws {
        startCount += 1
        do {
            while !mayFinish {
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

    func finish() {
        mayFinish = true
    }
}

private enum ProgressFailure: Error, Equatable {
    case expected(code: Int)
}

@Suite("Boot progress")
struct BootProgressTests {
    @Test("Sequential steps emit running and succeeded phases")
    func emitsEverySequentialPhase() async throws {
        let bootstrap = Bootstrap {
            BootStep("first") {}
            BootStep("second") {}
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        try await bootstrap.run()

        let firstRunning = try #require(await progress.next())
        let firstSucceeded = try #require(await progress.next())
        let secondRunning = try #require(await progress.next())
        let secondSucceeded = try #require(await progress.next())

        #expect(firstRunning.name == "first")
        #expect(firstRunning.attempt == 1)
        assertRunning(firstRunning.phase)
        #expect(firstSucceeded.id == firstRunning.id)
        assertSucceeded(firstSucceeded.phase)

        #expect(secondRunning.name == "second")
        #expect(secondRunning.id != firstRunning.id)
        assertRunning(secondRunning.phase)
        #expect(secondSucceeded.id == secondRunning.id)
        assertSucceeded(secondSucceeded.phase)
    }

    @Test("A failed step emits its retained failure")
    func emitsFailure() async throws {
        let bootstrap = Bootstrap {
            BootStep("failing") {
                throw ProgressFailure.expected(code: 17)
            }
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        await #expect(throws: ProgressFailure.self) {
            try await bootstrap.run()
        }

        let running = try #require(await progress.next())
        let failed = try #require(await progress.next())
        #expect(failed.id == running.id)
        guard case .failed(let failure) = failed.phase else {
            Issue.record("Expected a failed phase")
            return
        }
        #expect(failure.errorType == "ProgressFailure")
        #expect(
            failure.error as? ProgressFailure == .expected(code: 17)
        )
    }

    @Test("Non-blocking work emits continuing before its terminal phase")
    func emitsContinuingWork() async throws {
        let probe = ProgressProbe()
        let bootstrap = Bootstrap {
            BootStep("background") {
                try await probe.hold()
            }
            .nonBlocking()
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        try await bootstrap.run()

        let running = try #require(await progress.next())
        let continuing = try #require(await progress.next())
        #expect(continuing.id == running.id)
        assertRunning(running.phase)
        assertContinuing(continuing.phase)

        await probe.finish()
        while bootstrap.hasOutstandingNonBlockingSteps {
            await Task.yield()
        }

        let succeeded = try #require(await progress.next())
        #expect(succeeded.id == running.id)
        assertSucceeded(succeeded.phase)
    }

    @Test("A non-blocking failure emits after readiness remains ready")
    func emitsContainedFailureAfterReadiness() async throws {
        let signal = BootSignal<Void>("release-failure")
        let bootstrap = Bootstrap {
            BootStep("background") {}
                .waiting(for: signal) {
                    throw ProgressFailure.expected(code: 42)
                }
                .nonBlocking()
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        try await bootstrap.run()
        let running = try #require(await progress.next())
        let continuing = try #require(await progress.next())
        assertRunning(running.phase)
        assertContinuing(continuing.phase)

        signal.succeed()
        let failed = try #require(await progress.next())
        guard case .failed(let failure) = failed.phase else {
            Issue.record("Expected a failed phase")
            return
        }
        #expect(
            failure.error as? ProgressFailure == .expected(code: 42)
        )
        #expect(bootstrap.state == .ready)
    }

    @Test("Explicit cancellation emits a cancelled phase")
    func emitsCancellation() async throws {
        let probe = ProgressProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        bootstrap.start()
        await probe.waitForStarts(1)
        bootstrap.cancel()

        let running = try #require(await progress.next())
        let cancelled = try #require(await progress.next())
        #expect(cancelled.id == running.id)
        assertRunning(running.phase)
        assertCancelled(cancelled.phase)
    }

    @Test("Late subscribers receive the latest reached phases")
    func replaysLatestReachedPhases() async throws {
        let bootstrap = Bootstrap {
            BootStep("first") {}
            BootStep("second") {}
        }

        try await bootstrap.run()
        var progress = bootstrap.progress.makeAsyncIterator()

        let first = try #require(await progress.next())
        let second = try #require(await progress.next())
        #expect([first.name, second.name] == ["first", "second"])
        assertSucceeded(first.phase)
        assertSucceeded(second.phase)
    }

    @Test("Step identity distinguishes duplicate diagnostic names")
    func identifiesStepOccurrences() async throws {
        let bootstrap = Bootstrap {
            BootStep("configuration") {}
            BootStep("configuration") {}
        }

        try await bootstrap.run()
        var progress = bootstrap.progress.makeAsyncIterator()
        let first = try #require(await progress.next())
        let second = try #require(await progress.next())

        #expect(first.name == second.name)
        #expect(first.id != second.id)
    }

    @Test("Retries keep step identity and increment the attempt")
    func identifiesReplacementAttempts() async throws {
        let bootstrap = Bootstrap {
            BootStep("configuration") {}
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        try await bootstrap.run()
        let firstRunning = try #require(await progress.next())
        let firstSucceeded = try #require(await progress.next())

        try await bootstrap.run()
        let secondRunning = try #require(await progress.next())
        let secondSucceeded = try #require(await progress.next())

        #expect(firstRunning.attempt == 1)
        #expect(firstSucceeded.attempt == 1)
        #expect(secondRunning.attempt == 2)
        #expect(secondSucceeded.attempt == 2)
        #expect(secondRunning.id == firstRunning.id)
    }

    @Test("Replacement cancels active progress before the next attempt")
    func emitsReplacementCancellation() async throws {
        let probe = ProgressProbe()
        let bootstrap = Bootstrap {
            BootStep("configuration") {
                try await probe.hold()
            }
        }
        var progress = bootstrap.progress.makeAsyncIterator()

        bootstrap.start()
        await probe.waitForStarts(1)
        bootstrap.start()
        await probe.waitForCancellations(1)
        await probe.waitForStarts(2)
        await probe.finish()
        try await bootstrap.waitUntilReady()

        let firstRunning = try #require(await progress.next())
        let firstCancelled = try #require(await progress.next())
        let secondRunning = try #require(await progress.next())
        let secondSucceeded = try #require(await progress.next())

        #expect(firstRunning.attempt == 1)
        #expect(firstCancelled.attempt == 1)
        assertRunning(firstRunning.phase)
        assertCancelled(firstCancelled.phase)
        #expect(secondRunning.attempt == 2)
        #expect(secondSucceeded.attempt == 2)
        #expect(secondRunning.id == firstRunning.id)
        assertRunning(secondRunning.phase)
        assertSucceeded(secondSucceeded.phase)
    }

    @Test("Multiple progress subscribers receive the same phases")
    func broadcastsToMultipleSubscribers() async throws {
        let bootstrap = Bootstrap {
            BootStep("configuration") {}
        }
        var first = bootstrap.progress.makeAsyncIterator()
        var second = bootstrap.progress.makeAsyncIterator()

        try await bootstrap.run()

        for phase in [
            try #require(await first.next()).phase,
            try #require(await second.next()).phase,
        ] {
            assertRunning(phase)
        }
        for phase in [
            try #require(await first.next()).phase,
            try #require(await second.next()).phase,
        ] {
            assertSucceeded(phase)
        }
    }

    @Test("A progress stream finishes when Bootstrap is released")
    func finishesOnBootstrapRelease() async throws {
        let probe = ProgressProbe()
        var bootstrap: Bootstrap? = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        weak let weakBootstrap = bootstrap
        var progress = bootstrap!.progress.makeAsyncIterator()

        bootstrap!.start()
        await probe.waitForStarts(1)
        let running = try #require(await progress.next())
        assertRunning(running.phase)

        bootstrap = nil

        let cancelled = try #require(await progress.next())
        assertCancelled(cancelled.phase)
        #expect(await progress.next() == nil)
        #expect(weakBootstrap == nil)
    }

    @Test("Discarding a progress stream removes its subscription")
    func discardsUnusedSubscription() {
        let bootstrap = Bootstrap {
            BootStep("complete") {}
        }

        #expect(makeAndDiscardProgress(from: bootstrap) == 1)
        #expect(bootstrap.progressSubscriberCount == 0)
    }

    private func assertRunning(_ phase: BootProgress.Phase) {
        guard case .running = phase else {
            Issue.record("Expected a running phase")
            return
        }
    }

    private func assertContinuing(_ phase: BootProgress.Phase) {
        guard case .continuing = phase else {
            Issue.record("Expected a continuing phase")
            return
        }
    }

    private func assertSucceeded(_ phase: BootProgress.Phase) {
        guard case .succeeded = phase else {
            Issue.record("Expected a succeeded phase")
            return
        }
    }

    private func assertCancelled(_ phase: BootProgress.Phase) {
        guard case .cancelled = phase else {
            Issue.record("Expected a cancelled phase")
            return
        }
    }

    private func makeAndDiscardProgress(from bootstrap: Bootstrap) -> Int {
        let progress = bootstrap.progress
        let subscriberCount = bootstrap.progressSubscriberCount
        withExtendedLifetime(progress) {}
        return subscriberCount
    }
}
