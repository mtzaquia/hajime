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

/// Configures low-overhead performance measurements for a ``Bootstrap``.
///
/// Hajime emits Instruments signposts by default in both debug and release
/// builds. Use ``measurements(_:)`` to also forward completed intervals to an
/// analytics or observability system, or ``disabled`` to turn both paths off.
public struct BootInstrumentation: Sendable {
    /// One completed interval from a boot execution.
    public struct Measurement: Equatable, Sendable {
        /// The kind of boot work measured by an interval.
        public enum Scope: Equatable, Sendable {
            /// A start request until its execution becomes ready, fails, or is
            /// cancelled.
            case bootstrap

            /// The delay between a start request and execution of its plan.
            case scheduling

            /// A complete boot step, including its operation and requirements.
            case step(name: String, priority: TaskPriority)

            /// The initial operation of a boot step.
            case operation(step: String)

            /// A boot step waiting for one callback signal.
            case signalWait(signal: String, step: String)

            /// A boot step handling one or more resolved signal values.
            case signalHandler(signals: [String], step: String)

            /// A parallel group until all children finish or release readiness.
            case parallel

            /// Time a step remains active after it stops delaying readiness.
            case nonBlocking(step: String)

            /// Time a step is allowed to delay readiness before transitioning.
            case readinessBudget(step: String)
        }

        /// How the measured work ended.
        public enum Outcome: Equatable, Sendable {
            /// The work completed successfully.
            case succeeded

            /// The work threw an error.
            ///
            /// `errorType` contains only the concrete type name. Hajime never
            /// includes an error description or associated values.
            case failed(errorType: String)

            /// The work ended with `CancellationError`.
            case cancelled

            /// The interval ended because work stopped delaying readiness.
            ///
            /// The work itself remains active and later reports its own outcome.
            case releasedReadiness
        }

        /// The stable developer-authored name of the bootstrap coordinator.
        public let bootstrap: String

        /// An opaque identifier shared by measurements from one execution.
        public let runID: UUID

        /// The one-based execution number for this bootstrap coordinator.
        public let attempt: UInt64

        /// The kind of work represented by this interval.
        public let scope: Scope

        /// The interval's start relative to the matching start request.
        public let startOffset: Duration

        /// The elapsed time before the interval completed.
        public let duration: Duration

        /// How the measured work ended.
        public let outcome: Outcome
    }

    /// Emits boot intervals as Instruments signposts.
    public static let automatic = BootInstrumentation(
        emitsSignposts: true,
        handler: nil
    )

    /// Disables Instruments signposts and custom measurements.
    public static let disabled = BootInstrumentation(
        emitsSignposts: false,
        handler: nil
    )

    let emitsSignposts: Bool
    let handler: (@Sendable (Measurement) -> Void)?

    private init(
        emitsSignposts: Bool,
        handler: (@Sendable (Measurement) -> Void)?
    ) {
        self.emitsSignposts = emitsSignposts
        self.handler = handler
    }

    /// Emits Instruments signposts and forwards every completed interval.
    ///
    /// Hajime invokes `handler` synchronously on the task that completes the
    /// interval. The handler should record or enqueue the measurement in
    /// constant time; blocking it contributes to the remaining boot duration.
    /// Names are emitted as public diagnostic text, while signal values and
    /// error descriptions are never included.
    ///
    /// - Parameter handler: A thread-safe operation that accepts completed
    ///   intervals from any isolation context.
    /// - Returns: Instrumentation that emits signposts and measurements.
    public static func measurements(
        _ handler: @escaping @Sendable (Measurement) -> Void
    ) -> BootInstrumentation {
        BootInstrumentation(emitsSignposts: true, handler: handler)
    }
}

final class BootRunInstrumentation: Sendable {
    private let rootSpan: BootSpan?
    private let schedulingSpan: BootSpan?

    init(
        bootstrap: String,
        attempt: UInt64,
        configuration: BootInstrumentation
    ) {
        let signposter = configuration.emitsSignposts
            ? OSSignposter(
                subsystem: "eu.lelfe.hajime",
                category: "Performance"
            )
            : .disabled
        let descriptor = BootMeasurementDescriptor(
            bootstrap: bootstrap,
            runID: UUID(),
            attempt: attempt,
            requestInstant: ContinuousClock.now,
            signposter: signposter,
            handler: configuration.handler
        )

        guard signposter.isEnabled || configuration.handler != nil else {
            rootSpan = nil
            schedulingSpan = nil
            return
        }

        rootSpan = BootSpan(scope: .bootstrap, descriptor: descriptor)
        schedulingSpan = BootSpan(scope: .scheduling, descriptor: descriptor)
    }

    func measure<Result>(
        _ scope: BootInstrumentation.Measurement.Scope,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let span = start(scope) else {
            return try await operation()
        }

        do {
            let result = try await operation()
            span.finish(.succeeded)
            return result
        } catch {
            span.finish(.init(error))
            throw error
        }
    }

    func start(
        _ scope: BootInstrumentation.Measurement.Scope
    ) -> BootSpan? {
        guard let rootSpan else { return nil }
        return BootSpan(scope: scope, descriptor: rootSpan.descriptor)
    }

    func executionStarted() {
        schedulingSpan?.finish(.succeeded)
    }

    func finish(_ result: Result<Void, any Error>) {
        let outcome = BootInstrumentation.Measurement.Outcome(result)
        schedulingSpan?.finish(outcome)
        rootSpan?.finish(outcome)
    }
}

struct BootMeasurementDescriptor: Sendable {
    let bootstrap: String
    let runID: UUID
    let attempt: UInt64
    let requestInstant: ContinuousClock.Instant
    let signposter: OSSignposter
    let handler: (@Sendable (BootInstrumentation.Measurement) -> Void)?
}

final class BootSpan: Sendable {
    let descriptor: BootMeasurementDescriptor

    private struct Storage {
        var isFinished = false
    }

    private let scope: BootInstrumentation.Measurement.Scope
    private let start: ContinuousClock.Instant
    private let intervalState: OSSignpostIntervalState?
    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    init(
        scope: BootInstrumentation.Measurement.Scope,
        descriptor: BootMeasurementDescriptor
    ) {
        self.scope = scope
        self.descriptor = descriptor
        start = ContinuousClock.now

        if descriptor.signposter.isEnabled {
            intervalState = descriptor.signposter.beginInterval(
                scope.signpostName,
                id: descriptor.signposter.makeSignpostID(),
                "bootstrap=\(descriptor.bootstrap, privacy: .public) run=\(descriptor.runID.uuidString, privacy: .public) attempt=\(descriptor.attempt) scope=\(scope.signpostDescription, privacy: .public)"
            )
        } else {
            intervalState = nil
        }
    }

    func finish(_ outcome: BootInstrumentation.Measurement.Outcome) {
        let shouldFinish = lock.withLock { storage in
            guard !storage.isFinished else { return false }
            storage.isFinished = true
            return true
        }
        guard shouldFinish else { return }

        let end = ContinuousClock.now
        if let intervalState {
            descriptor.signposter.endInterval(
                scope.signpostName,
                intervalState,
                "outcome=\(outcome.signpostDescription, privacy: .public)"
            )
        }

        descriptor.handler?(
            BootInstrumentation.Measurement(
                bootstrap: descriptor.bootstrap,
                runID: descriptor.runID,
                attempt: descriptor.attempt,
                scope: scope,
                startOffset: descriptor.requestInstant.duration(to: start),
                duration: start.duration(to: end),
                outcome: outcome
            )
        )
    }
}

private extension BootInstrumentation.Measurement.Scope {
    var signpostName: StaticString {
        switch self {
        case .bootstrap: "Boot"
        case .scheduling: "Scheduling"
        case .step: "Step"
        case .operation: "Operation"
        case .signalWait: "Signal Wait"
        case .signalHandler: "Signal Handler"
        case .parallel: "Parallel"
        case .nonBlocking: "Non-Blocking"
        case .readinessBudget: "Readiness Budget"
        }
    }

    var signpostDescription: String {
        switch self {
        case .bootstrap:
            "bootstrap"
        case .scheduling:
            "scheduling"
        case let .step(name, priority):
            "step:\(name):\(priority.hajimeDescription)"
        case .operation(let step):
            "operation:\(step)"
        case let .signalWait(signal, step):
            "signal_wait:\(step):\(signal)"
        case let .signalHandler(signals, step):
            "signal_handler:\(step):\(signals.joined(separator: ","))"
        case .parallel:
            "parallel"
        case .nonBlocking(let step):
            "non_blocking:\(step)"
        case .readinessBudget(let step):
            "readiness_budget:\(step)"
        }
    }
}

extension BootInstrumentation.Measurement.Outcome {
    init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
        } else {
            self = .failed(errorType: error.hajimeTypeDescription)
        }
    }

    init(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            self = .succeeded
        case .failure(let error):
            self.init(error)
        }
    }

    var signpostDescription: String {
        switch self {
        case .succeeded:
            "succeeded"
        case .failed(let errorType):
            "failed:\(errorType)"
        case .cancelled:
            "cancelled"
        case .releasedReadiness:
            "released_readiness"
        }
    }
}
