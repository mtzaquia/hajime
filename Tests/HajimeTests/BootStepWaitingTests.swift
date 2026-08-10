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

private actor WaitingTrace {
    private(set) var events: [String] = []
    private var isHandlerReleased = false

    func append(_ event: String) {
        events.append(event)
    }

    func holdHandler() async {
        events.append("handler-started")
        while !isHandlerReleased {
            await Task.yield()
        }
        events.append("handler-finished")
    }

    func waitForEvent(_ event: String) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }

    func releaseHandler() {
        isHandlerReleased = true
    }
}

private enum WaitingFailure: Error {
    case signal
    case handler
}

@Suite("Boot step signal requirements")
struct BootStepWaitingTests {
    @Test("A step finishes only after its signal handler finishes")
    func extendsStepThroughHandlerCompletion() async throws {
        let signal = BootSignal<Int>("push-registration")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-push") {
                await trace.append("operation-finished")
            }
            .waiting(for: signal) { value in
                #expect(value == 42)
                await trace.holdHandler()
            }
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        #expect(bootstrap.state == .booting)

        signal.succeed(42)
        await trace.waitForEvent("handler-started")
        #expect(bootstrap.state == .booting)

        await trace.releaseHandler()
        try await bootstrap.waitUntilReady()

        #expect(await trace.events == [
            "operation-finished",
            "handler-started",
            "handler-finished",
        ])
    }

    @Test("A signal failure skips its handler and fails the step")
    func propagatesSignalFailure() async {
        let signal = BootSignal<Int>("push-registration")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .waiting(for: signal) { _ in
                    await trace.append("handler-ran")
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.fail(WaitingFailure.signal)

        await #expect(throws: WaitingFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        #expect(await trace.events.isEmpty)
        #expect(bootstrap.state == .failed)
    }

    @Test("A signal handler failure fails the step")
    func propagatesHandlerFailure() async {
        let signal = BootSignal<Int>("push-registration")
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .waiting(for: signal) { _ in
                    throw WaitingFailure.handler
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.succeed(1)

        await #expect(throws: WaitingFailure.self) {
            try await bootstrap.waitUntilReady()
        }
    }

    @Test("Chained requirements wait and handle results concurrently")
    func waitsForChainedSignalsConcurrently() async throws {
        let push = BootSignal<Int>("push-registration")
        let attestation = BootSignal<String>("app-attestation")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-services") {}
                .waiting(for: push) { value in
                    await trace.append("push-\(value)")
                }
                .waiting(for: attestation) { value in
                    await trace.append("attestation-\(value)")
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: push)
        await waitForWaiters(1, on: attestation)

        attestation.succeed("ready")
        await trace.waitForEvent("attestation-ready")
        #expect(bootstrap.state == .booting)

        push.succeed(7)
        try await bootstrap.waitUntilReady()

        let events = await trace.events
        #expect(events.contains("push-7"))
        #expect(events.contains("attestation-ready"))
    }

    @Test("A chained failure cancels sibling waits")
    func cancelsSiblingWaitAfterFailure() async {
        let push = BootSignal<Int>("push-registration")
        let attestation = BootSignal<String>("app-attestation")
        let bootstrap = Bootstrap {
            BootStep("register-services") {}
                .waiting(for: push)
                .waiting(for: attestation)
        }

        bootstrap.start()
        await waitForWaiters(1, on: push)
        await waitForWaiters(1, on: attestation)
        push.fail(WaitingFailure.signal)

        await #expect(throws: WaitingFailure.self) {
            try await bootstrap.waitUntilReady()
        }
        await waitForWaiters(0, on: attestation)
    }

    @Test("A grouped handler receives two values after both signals resolve")
    func waitsForGroupedSignals() async throws {
        let push = BootSignal<Int>("push-registration")
        let attestation = BootSignal<String>("app-attestation")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-services") {}
                .waiting(for: push, attestation) { token, assertion in
                    await trace.append("combined-\(token)-\(assertion)")
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: push)
        await waitForWaiters(1, on: attestation)

        push.succeed(8)
        await Task.yield()
        #expect(await trace.events.isEmpty)

        attestation.succeed("valid")
        try await bootstrap.waitUntilReady()
        #expect(await trace.events == ["combined-8-valid"])
    }

    @Test("A grouped handler can receive three heterogeneous values")
    func waitsForThreeGroupedSignals() async throws {
        let push = BootSignal<Int>("push-registration")
        let attestation = BootSignal<String>("app-attestation")
        let migration = BootSignal<Void>("migration")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-services") {}
                .waiting(
                    for: push,
                    attestation,
                    migration
                ) { token, assertion, _ in
                    await trace.append("combined-\(token)-\(assertion)")
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: push)
        await waitForWaiters(1, on: attestation)
        await waitForWaiters(1, on: migration)
        push.succeed(9)
        attestation.succeed("valid")
        migration.succeed()

        try await bootstrap.waitUntilReady()
        #expect(await trace.events == ["combined-9-valid"])
    }

    @Test("A managed signal is rearmed for a replacement run")
    func rearmsSignalForRetry() async throws {
        let signal = BootSignal<Int>("push-registration")
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .waiting(for: signal) { value in
                    await trace.append("token-\(value)")
                }
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.succeed(1)
        try await bootstrap.waitUntilReady()

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        #expect(bootstrap.state == .booting)
        signal.succeed(2)
        try await bootstrap.waitUntilReady()

        #expect(await trace.events == ["token-1", "token-2"])
    }

    @Test("A failed managed signal can succeed on retry")
    func rearmsFailedSignalForRetry() async throws {
        let signal = BootSignal<Int>("push-registration")
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .waiting(for: signal)
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.fail(WaitingFailure.signal)
        await #expect(throws: WaitingFailure.self) {
            try await bootstrap.waitUntilReady()
        }

        bootstrap.start()
        await waitForWaiters(1, on: signal)
        signal.succeed(2)
        try await bootstrap.waitUntilReady()
        #expect(bootstrap.state == .ready)
    }

    @Test("A result before the first run is adopted by that run")
    func adoptsPreflightResolution() async throws {
        let signal = BootSignal<Int>("push-registration")
        signal.succeed(11)
        let trace = WaitingTrace()
        let bootstrap = Bootstrap {
            BootStep("register-push") {}
                .waiting(for: signal) { value in
                    await trace.append("token-\(value)")
                }
        }

        try await bootstrap.run()

        #expect(await trace.events == ["token-11"])
    }

    @Test("Waiting on an undeclared signal fails instead of hanging")
    func failsForUnregisteredSignal() async {
        let signal = BootSignal<Int>("forgotten-signal")
        let bootstrap = Bootstrap {
            BootStep("invalid") {
                _ = try await signal.wait()
            }
        }

        await #expect(
            throws: BootSignalError.notRegistered(
                signal: "forgotten-signal"
            )
        ) {
            try await bootstrap.run()
        }
        #expect(bootstrap.state == .failed)
    }

    @Test("One signal cannot be managed by two bootstraps")
    func rejectsAnotherBootstrapOwner() async throws {
        let signal = BootSignal<Int>("shared-signal")
        let first = Bootstrap {
            BootStep("first") {}
                .waiting(for: signal)
        }

        first.start()
        await waitForWaiters(1, on: signal)
        signal.succeed(1)
        try await first.waitUntilReady()

        let second = Bootstrap {
            BootStep("second") {}
                .waiting(for: signal)
        }

        await #expect(
            throws: BootSignalError.registeredToAnotherBootstrap(
                signal: "shared-signal"
            )
        ) {
            try await second.run()
        }
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
