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

private actor BootSuspensionProbe {
    private var startCount = 0
    private var cancellationCount = 0
    private var isReleased = false
    private(set) var maximumActiveCount = 0
    private var activeCount = 0

    func hold() async throws {
        startCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }

        do {
            while !isReleased {
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func waitForStarts(_ expectedCount: Int) async {
        while startCount < expectedCount {
            await Task.yield()
        }
    }

    func waitForCancellations(_ expectedCount: Int) async {
        while cancellationCount < expectedCount {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }
}

private enum ReadinessFailure: Error {
    case expected
}

@Suite("Bootstrap readiness")
struct BootstrapReadinessTests {
    @Test("A waiter can suspend before boot starts")
    func waitsFromIdleUntilReady() async throws {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }

        #expect(bootstrap.state == .idle)
        #expect(!bootstrap.isReady)

        let waiter = Task {
            try await bootstrap.waitUntilReady()
        }
        bootstrap.start()
        await probe.waitForStarts(1)

        #expect(bootstrap.state == .booting)
        #expect(!bootstrap.isReady)

        await probe.release()
        try await waiter.value

        #expect(bootstrap.state == .ready)
        #expect(bootstrap.isReady)
    }

    @Test("Concurrent readiness waiters share one execution")
    func resumesConcurrentWaiters() async throws {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }

        bootstrap.start()
        await probe.waitForStarts(1)

        let waiters = (0..<20).map { _ in
            Task {
                try await bootstrap.waitUntilReady()
            }
        }

        await probe.release()
        for waiter in waiters {
            try await waiter.value
        }

        #expect(bootstrap.state == .ready)
    }

    @Test("Starting again supersedes the run without dropping waiters")
    func supersedesCurrentExecution() async throws {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        let waiter = Task {
            try await bootstrap.waitUntilReady()
        }

        bootstrap.start()
        await probe.waitForStarts(1)
        bootstrap.start()
        await probe.waitForStarts(2)
        await probe.waitForCancellations(1)

        #expect(bootstrap.state == .booting)

        await probe.release()
        try await waiter.value

        #expect(bootstrap.state == .ready)
        #expect(bootstrap.isReady)
        #expect(await probe.maximumActiveCount == 1)
    }

    @Test("Concurrent start requests still form one readiness pipe")
    func serializesConcurrentStarts() async throws {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    bootstrap.start()
                }
            }
        }

        await probe.release()
        try await bootstrap.waitUntilReady()

        #expect(bootstrap.state == .ready)
        #expect(await probe.maximumActiveCount == 1)
    }

    @Test("Cancelling one waiter does not cancel boot")
    func isolatesWaiterCancellation() async throws {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }

        bootstrap.start()
        await probe.waitForStarts(1)

        let waiter = Task {
            try await bootstrap.waitUntilReady()
        }
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(bootstrap.state == .booting)

        await probe.release()
        try await bootstrap.waitUntilReady()

        #expect(bootstrap.state == .ready)
    }

    @Test("A failure is observable through state and every waiter")
    func propagatesBootFailure() async {
        let bootstrap = Bootstrap {
            BootStep("failing") {
                throw ReadinessFailure.expected
            }
        }

        bootstrap.start()

        await #expect(throws: ReadinessFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        await #expect(throws: ReadinessFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        guard case .failed = bootstrap.state else {
            Issue.record("Expected boot to fail")
            return
        }
        #expect(!bootstrap.isReady)
    }

    @Test("Cancelling after readiness does not rewrite the result")
    func preservesCompletedReadiness() async throws {
        let bootstrap = Bootstrap {
            BootStep("complete") {}
        }

        bootstrap.start()
        try await bootstrap.waitUntilReady()
        bootstrap.cancel()

        #expect(bootstrap.state == .ready)
        #expect(bootstrap.isReady)
        try await bootstrap.waitUntilReady()
    }

    @Test("Explicit cancellation ends the pipe and its waiters")
    func cancelsExecutionAndWaiters() async {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }

        bootstrap.start()
        await probe.waitForStarts(1)
        let waiter = Task {
            try await bootstrap.waitUntilReady()
        }

        bootstrap.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        await probe.waitForCancellations(1)
        #expect(bootstrap.state == .cancelled)
        #expect(!bootstrap.isReady)
    }

    @Test("Cancelling run cancels the shared execution")
    func runOwnsExecutionCancellation() async {
        let probe = BootSuspensionProbe()
        let bootstrap = Bootstrap {
            BootStep("suspended") {
                try await probe.hold()
            }
        }
        let run = Task {
            try await bootstrap.run()
        }

        await probe.waitForStarts(1)
        run.cancel()

        await #expect(throws: CancellationError.self) {
            try await run.value
        }
        await probe.waitForCancellations(1)
        #expect(bootstrap.state == .cancelled)
    }
}
