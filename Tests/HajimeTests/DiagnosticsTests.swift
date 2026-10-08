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
import Testing
@testable import Hajime

private struct SensitiveFailure: LocalizedError {
    let errorDescription: String? = "token=customer-secret"
}

private actor TraceIdentifierProbe {
    private(set) var value: String?

    func record(_ value: String?) {
        self.value = value
    }
}

@Suite("Hajime diagnostics", .serialized)
struct DiagnosticsTests {
    @Test("Timing events separate readiness, scheduling, and background work")
    func rendersTimingBreakdown() throws {
        let runID = try #require(UUID(uuidString: "12345678-0000-0000-0000-000000000000"))
        let measurement = BootInstrumentation.Measurement(
            bootstrap: "app-launch", runID: runID, attempt: 2,
            scope: .readinessBudget(step: "sync-icloud"),
            startOffset: .milliseconds(125), duration: .seconds(2),
            outcome: .releasedReadiness
        )
        #expect(HajimeLogEvent.timing(measurement).message ==
            "[timing][12345678] • measured | boot=\"app-launch\" attempt=2 scope=readiness_budget step=\"sync-icloud\" start=0.125s elapsed=2.000s outcome=released_readiness")
        let normal: [BootInstrumentation.Measurement.Scope] = [
            .bootstrap, .scheduling, .step(name: "store", priority: .userInitiated),
            .signalWait(signal: "callback", step: "store"),
            .nonBlocking(step: "sync"), .readinessBudget(step: "sync")
        ]
        let trace: [BootInstrumentation.Measurement.Scope] = [
            .operation(step: "store"), .signalHandler(signals: ["callback"], step: "store"), .parallel
        ]
        for scope in normal { #expect(scope.timingLogLevel == .normal) }
        for scope in trace { #expect(scope.timingLogLevel == .trace) }
        #expect(BootInstrumentation.Measurement.Scope.operation(step: "a\nb").timingDescription ==
            "scope=operation step=\"a\\nb\"")
        let failure = BootInstrumentation.Measurement(
            bootstrap: "app-launch", runID: runID, attempt: 2,
            scope: .bootstrap, startOffset: .zero, duration: .zero,
            outcome: .init(SensitiveFailure())
        )
        #expect(!HajimeLogEvent.timing(failure).message.contains("customer-secret"))
        #expect(HajimeLogEvent.timing(failure).message.contains("outcome=failed:SensitiveFailure"))
    }

    @Test("Timing diagnostics work without an Instruments recording and respect disabled")
    func activatesTimingDiagnostics() {
        let previous = Hajime.debug
        defer { Hajime.debug = previous }
        Hajime.debug = .normal
        let automatic = BootRunInstrumentation(bootstrap: "launch", attempt: 1, configuration: .automatic)
        #expect(automatic.traceID != nil)
        #expect(automatic.start(.step(name: "store", priority: .userInitiated)) != nil)
        let disabled = BootRunInstrumentation(bootstrap: "launch", attempt: 1, configuration: .disabled)
        #expect(disabled.traceID == nil)
        #expect(disabled.start(.bootstrap) == nil)
    }

    @Test("Every event has a deliberate minimum level")
    func assignsEventLevels() {
        let normalEvents: [HajimeLogEvent] = [
            .bootStarted(
                stepCount: 4,
                parallelGroupCount: 1,
                nonBlockingStepCount: 1
            ),
            .bootSucceeded,
            .bootCancelled,
            .bootFailed(error: SensitiveFailure()),
            .stepStarted(name: "session", priority: .userInitiated),
            .stepSucceeded(name: "session"),
            .stepCancelled(name: "session"),
            .stepFailed(name: "session", error: SensitiveFailure()),
            .stepBecameNonBlocking(name: "session", after: nil),
            .stepBecameNonBlocking(
                name: "configuration",
                after: .milliseconds(250)
            ),
            .signalWaitRequested(name: "push-registration"),
            .signalWaitCancelled(name: "push-registration"),
            .signalSucceeded(name: "push-registration"),
            .signalFailed(
                name: "push-registration",
                error: SensitiveFailure()
            ),
        ]
        let traceEvents: [HajimeLogEvent] = [
            .parallelStarted(childCount: 2),
            .parallelSucceeded(childCount: 2),
            .parallelCancelled(childCount: 2),
            .parallelFailed(childCount: 2, error: SensitiveFailure()),
            .signalArmed(name: "push-registration", replacedRun: false),
            .signalArmed(name: "push-registration", replacedRun: true),
            .signalResultReplayed(name: "push-registration"),
            .signalDuplicateResolutionIgnored(name: "push-registration"),
        ]

        for event in normalEvents {
            #expect(event.logLevel == .normal)
        }
        for event in traceEvents {
            #expect(event.logLevel == .trace)
        }
    }

    @Test("Log levels include only their intended events")
    func includesExpectedLevels() {
        let expectations: [
            (configured: Hajime.DebugLogLevel, event: Hajime.DebugLogLevel, included: Bool)
        ] = [
            (.off, .off, true),
            (.off, .normal, false),
            (.off, .trace, false),
            (.normal, .off, false),
            (.normal, .normal, true),
            (.normal, .trace, false),
            (.trace, .off, true),
            (.trace, .normal, true),
            (.trace, .trace, true),
        ]

        for expectation in expectations {
            #expect(
                expectation.configured.includes(expectation.event)
                    == expectation.included
            )
        }
    }

    @Test("Events render stable correlated messages")
    func rendersStableMessages() {
        let messages = HajimeLogTrace.$id.withValue("12345678") {
            [
                HajimeLogEvent.bootStarted(
                    stepCount: 4,
                    parallelGroupCount: 1,
                    nonBlockingStepCount: 1
                ).message,
                HajimeLogEvent.stepStarted(
                    name: "restore-session",
                    priority: .userInitiated
                ).message,
                HajimeLogEvent.stepSucceeded(
                    name: "restore-session"
                ).message,
                HajimeLogEvent.parallelStarted(childCount: 2).message,
                HajimeLogEvent.signalWaitRequested(
                    name: "push-registration"
                ).message,
                HajimeLogEvent.signalArmed(
                    name: "push-registration",
                    replacedRun: false
                ).message,
                HajimeLogEvent.signalArmed(
                    name: "push-registration",
                    replacedRun: true
                ).message,
                HajimeLogEvent.signalSucceeded(
                    name: "push-registration"
                ).message,
                HajimeLogEvent.signalResultReplayed(
                    name: "push-registration"
                ).message,
                HajimeLogEvent.signalDuplicateResolutionIgnored(
                    name: "push-registration"
                ).message,
                HajimeLogEvent.bootSucceeded.message,
            ]
        }

        #expect(messages == [
            "[boot][12345678] → started | steps=4 parallel_groups=1 non_blocking_steps=1",
            "[step][12345678] → started | step=\"restore-session\" priority=user_initiated",
            "[step][12345678] ✓ completed | step=\"restore-session\"",
            "[parallel][12345678] → started | children=2",
            "[signal][12345678] ⏳ waiting | signal=\"push-registration\"",
            "[signal][12345678] → armed | signal=\"push-registration\"",
            "[signal][12345678] ↻ rearmed | signal=\"push-registration\"",
            "[signal][12345678] ✓ succeeded | signal=\"push-registration\"",
            "[signal][12345678] ← replayed stored result | signal=\"push-registration\"",
            "[signal][12345678] ⊘ duplicate resolution ignored | signal=\"push-registration\"",
            "[boot][12345678] ✓ completed",
        ])
    }

    @Test("Configuration warnings are actionable and privacy safe")
    func rendersSignalConfigurationWarnings() {
        let missing = HajimeWarning.signalConfigurationFailure(
            .notRegistered(signal: "push-registration")
        ).message
        let shared = HajimeWarning.signalConfigurationFailure(
            .registeredToAnotherBootstrap(signal: "push-registration")
        ).message

        #expect(
            missing
                == "[signal] ⚠︎ not registered with the current bootstrap; declare it with BootStep.waiting(for:) | signal=\"push-registration\""
        )
        #expect(
            shared
                == "[signal] ⚠︎ already registered with another bootstrap | signal=\"push-registration\""
        )
    }

    @Test("Readiness release events identify the step and duration")
    func rendersReadinessRelease() {
        let messages = HajimeLogTrace.$id.withValue("12345678") {
            [
                HajimeLogEvent.stepBecameNonBlocking(
                    name: "warm-cache",
                    after: nil
                ).message,
                HajimeLogEvent.stepBecameNonBlocking(
                    name: "restore-content",
                    after: .milliseconds(250)
                ).message,
            ]
        }

        #expect(messages == [
            "[step][12345678] ↗ released readiness | step=\"warm-cache\" after=immediate",
            "[step][12345678] ↗ released readiness | step=\"restore-content\" after=0.250s",
        ])
    }

    @Test("Step names are quoted and escaped")
    func escapesStepNames() {
        let message = HajimeLogEvent.stepStarted(
            name: "restore-\nsession",
            priority: .utility
        ).message

        #expect(
            message
                == "[step] → started | step=\"restore-\\nsession\" priority=utility"
        )
    }

    @Test("Failures render only the error type")
    func omitsSensitiveErrorDescriptions() {
        let bootMessage = HajimeLogEvent.bootFailed(
            error: SensitiveFailure()
        ).message
        let stepMessage = HajimeLogEvent.stepFailed(
            name: "session",
            error: SensitiveFailure()
        ).message
        let signalMessage = HajimeLogEvent.signalFailed(
            name: "push-registration",
            error: SensitiveFailure()
        ).message

        #expect(bootMessage.contains("error=SensitiveFailure"))
        #expect(stepMessage.contains("error=SensitiveFailure"))
        #expect(signalMessage.contains("error=SensitiveFailure"))
        #expect(!bootMessage.contains("customer-secret"))
        #expect(!stepMessage.contains("customer-secret"))
        #expect(!signalMessage.contains("customer-secret"))
    }

    @Test("Disabled diagnostics do not construct events")
    func disabledDiagnosticsAreLazy() {
        Hajime.debug = .off
        var constructed = false

        hajimeLog.hajimeDebug(makeEvent(constructed: &constructed))

        #expect(!constructed)
    }

    @Test("A run trace identifier is unique, nested, and restored")
    func managesTraceIdentifiers() async throws {
        #expect(HajimeLogTrace.id == nil)

        let values = await HajimeLogTrace.$id.withValue("outer") {
            let beforeNestedTrace = HajimeLogTrace.id
            let nestedTrace = await HajimeLogTrace.withNewID {
                HajimeLogTrace.id
            }
            let afterNestedTrace = HajimeLogTrace.id
            return (beforeNestedTrace, nestedTrace, afterNestedTrace)
        }
        let anotherTrace = await HajimeLogTrace.withNewID {
            HajimeLogTrace.id
        }

        #expect(values.0 == "outer")
        #expect(try #require(values.1).count == 8)
        #expect(values.1 != "outer")
        #expect(values.2 == "outer")
        #expect(try #require(anotherTrace).count == 8)
        #expect(anotherTrace != values.1)
        #expect(HajimeLogTrace.id == nil)
    }

    @Test("A step inherits its run trace identifier")
    func propagatesTraceIdentifierIntoStepTask() async throws {
        let probe = TraceIdentifierProbe()
        let bootstrap = Bootstrap {
            BootStep("trace-probe") {
                await probe.record(HajimeLogTrace.id)
            }
        }

        try await bootstrap.run()

        #expect(try #require(await probe.value).count == 8)
    }

    @Test("Configuration is available outside the main actor")
    func configuresOutsideMainActor() async {
        defer { Hajime.debug = .off }

        let level = await Task.detached {
            Hajime.debug = .normal
            return Hajime.debug
        }.value

        #expect(level == .normal)
    }

    @Test("Configuration supports concurrent access")
    func supportsConcurrentConfigurationAccess() async {
        defer { Hajime.debug = .off }
        let levels = [
            Hajime.DebugLogLevel.off,
            .normal,
            .trace,
        ]

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    Hajime.debug = levels[index % levels.count]
                    _ = Hajime.debug
                }
            }
        }

        Hajime.debug = .trace
        #expect(Hajime.debug == .trace)
    }

    private func makeEvent(
        constructed: inout Bool
    ) -> HajimeLogEvent {
        constructed = true
        return .bootSucceeded
    }
}
