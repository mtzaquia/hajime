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

private enum SignalFailure: Error {
    case expected
}

private enum DuplicateSignalFailure: Error {
    case ignored
}

@Suite("Boot signals")
struct BootSignalTests {
    @Test("Success is buffered before the first waiter")
    func buffersEarlySuccess() async throws {
        let signal = BootSignal<Int>("remote-configuration")

        signal.succeed(42)

        #expect(try await signal.wait() == 42)
        #expect(try await signal.wait() == 42)
    }

    @Test("A late success resumes its waiter")
    func deliversLateSuccess() async throws {
        let signal = BootSignal<String>("push-registration")
        let waiter = Task {
            try await signal.wait()
        }
        await waitForWaiters(1, on: signal)

        signal.succeed("registered")

        #expect(try await waiter.value == "registered")
    }

    @Test("Failure is buffered before the first waiter")
    func buffersEarlyFailure() async {
        let signal = BootSignal<Int>("remote-configuration")

        signal.fail(SignalFailure.expected)

        await #expect(throws: SignalFailure.self) {
            try await signal.wait()
        }
        await #expect(throws: SignalFailure.self) {
            try await signal.wait()
        }
    }

    @Test("A late failure resumes its waiter")
    func deliversLateFailure() async {
        let signal = BootSignal<Int>("push-registration")
        let waiter = Task {
            try await signal.wait()
        }
        await waitForWaiters(1, on: signal)

        signal.fail(SignalFailure.expected)

        await #expect(throws: SignalFailure.self) {
            try await waiter.value
        }
    }

    @Test("Concurrent waiters receive the same result")
    func resumesMultipleWaiters() async throws {
        let signal = BootSignal<Int>("account-restoration")
        let waiters = (0..<20).map { _ in
            Task {
                try await signal.wait()
            }
        }
        await waitForWaiters(waiters.count, on: signal)

        signal.succeed(7)

        for waiter in waiters {
            #expect(try await waiter.value == 7)
        }
    }

    @Test("Cancelling one waiter leaves the signal and other waiters intact")
    func isolatesWaiterCancellation() async throws {
        let signal = BootSignal<Int>("account-restoration")
        let cancelledWaiter = Task {
            try await signal.wait()
        }
        let survivingWaiter = Task {
            try await signal.wait()
        }
        await waitForWaiters(2, on: signal)

        cancelledWaiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        await waitForWaiters(1, on: signal)

        signal.succeed(9)

        #expect(try await survivingWaiter.value == 9)
        #expect(try await signal.wait() == 9)
    }

    @Test("The first success wins over duplicate resolutions")
    func keepsFirstSuccessfulResolution() async throws {
        let signal = BootSignal<Int>("push-registration")

        signal.succeed(1)
        signal.succeed(2)
        signal.fail(DuplicateSignalFailure.ignored)

        #expect(try await signal.wait() == 1)
    }

    @Test("The first failure wins over duplicate resolutions")
    func keepsFirstFailedResolution() async {
        let signal = BootSignal<Int>("push-registration")

        signal.fail(SignalFailure.expected)
        signal.succeed(2)
        signal.fail(DuplicateSignalFailure.ignored)

        await #expect(throws: SignalFailure.self) {
            try await signal.wait()
        }
    }

    @Test("Void signals provide a value-free success convenience")
    func succeedsWithoutValue() async throws {
        let signal = BootSignal<Void>("migration-finished")

        signal.succeed()

        try await signal.wait()
    }

    @Test("Resolve accepts a successful Result")
    func resolvesSuccessfulResult() async throws {
        let signal = BootSignal<Int>("remote-configuration")

        signal.resolve(Result<Int, SignalFailure>.success(17))

        #expect(try await signal.wait() == 17)
    }

    @Test("Resolve accepts a failed Result")
    func resolvesFailedResult() async {
        let signal = BootSignal<Int>("remote-configuration")

        signal.resolve(Result<Int, SignalFailure>.failure(.expected))

        await #expect(throws: SignalFailure.self) {
            try await signal.wait()
        }
    }

    @Test("Concurrent synchronous resolutions are safe and first-wins")
    func resolvesConcurrently() async throws {
        let signal = BootSignal<Int>("delegate-race")

        await withTaskGroup(of: Void.self) { group in
            for value in 0..<100 {
                group.addTask {
                    signal.succeed(value)
                }
            }
        }

        #expect((0..<100).contains(try await signal.wait()))
    }

    @Test("Late fulfillment is safe after cancellation and retry rearms")
    func fulfillsAfterBootCancellation() async throws {
        let signal = BootSignal<Void>("push-registration")
        let bootstrap = Bootstrap {
            BootStep("await-push-registration") {}
                .waiting(for: signal)
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        bootstrap.cancel()

        await #expect(throws: CancellationError.self) {
            try await bootstrap.waitUntilReady()
        }
        await waitForWaiters(0, on: signal)

        signal.succeed()
        await #expect(throws: CancellationError.self) {
            try await signal.wait()
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.succeed()
        try await bootstrap.waitUntilReady()
        try await signal.wait()
    }

    @Test("Synchronous fulfillment is callable from the main actor")
    @MainActor
    func fulfillsFromMainActor() async throws {
        let signal = BootSignal<Int>("delegate-callback")

        signal.succeed(23)

        #expect(try await signal.wait() == 23)
    }

    private func waitForWaiters<Value: Sendable>(
        _ count: Int,
        on signal: BootSignal<Value>
    ) async {
        while signal.pendingWaiterCount != count {
            await Task.yield()
        }
    }
}
