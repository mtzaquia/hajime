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

/// A namespace for process-wide Hajime configuration.
public enum Hajime {
    /// The amount of boot-orchestration detail emitted in debug builds.
    public enum DebugLogLevel: Equatable, Sendable {
        /// Emits no Hajime diagnostics.
        case off

        /// Logs boot, step, readiness-release, and signal lifecycle outcomes.
        case normal

        /// Adds parallel boundaries and detailed signal lifecycle events.
        case trace
    }

    private nonisolated static let debugLock =
        OSAllocatedUnfairLock(initialState: DebugLogLevel.off)

    /// Controls the process-wide diagnostics emitted by Hajime in debug builds.
    ///
    /// Logging is ``DebugLogLevel/off`` by default, and reads and writes are safe
    /// from concurrent tasks. Each boot execution receives a trace identifier
    /// inherited by its steps. Diagnostic calls are compiled out when the
    /// Hajime module is built without `DEBUG`.
    ///
    /// ```swift
    /// Hajime.debug = .trace
    /// ```
    public nonisolated static var debug: DebugLogLevel {
        get { debugLock.withLock { $0 } }
        set { debugLock.withLock { $0 = newValue } }
    }
}

nonisolated let hajimeLog = Logger(
    subsystem: "eu.lelfe.hajime",
    category: "Hajime"
)

enum HajimeLogTrace {
    @TaskLocal static var id: String?

    static func withNewID<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
#if DEBUG
        let id = String(UUID().uuidString.prefix(8))
        return try await $id.withValue(id, operation: operation)
#else
        return try await operation()
#endif
    }
}

enum HajimeLogEvent {
    case bootStarted(
        stepCount: Int,
        parallelGroupCount: Int,
        nonBlockingStepCount: Int
    )
    case bootSucceeded
    case bootCancelled
    case bootFailed(error: any Error)
    case stepStarted(name: String, priority: TaskPriority)
    case stepSucceeded(name: String)
    case stepCancelled(name: String)
    case stepFailed(name: String, error: any Error)
    case stepBecameNonBlocking(name: String, after: Duration?)
    case parallelStarted(childCount: Int)
    case parallelSucceeded(childCount: Int)
    case parallelCancelled(childCount: Int)
    case parallelFailed(childCount: Int, error: any Error)
    case signalWaitRequested(name: String)
    case signalWaitCancelled(name: String)
    case signalSucceeded(name: String)
    case signalFailed(name: String, error: any Error)
    case signalArmed(name: String, replacedRun: Bool)
    case signalResultReplayed(name: String)
    case signalDuplicateResolutionIgnored(name: String)

    var logLevel: Hajime.DebugLogLevel {
        switch self {
        case .bootStarted,
             .bootSucceeded,
             .bootCancelled,
             .bootFailed,
             .stepStarted,
             .stepSucceeded,
             .stepCancelled,
             .stepFailed,
             .stepBecameNonBlocking,
             .signalWaitRequested,
             .signalWaitCancelled,
             .signalSucceeded,
             .signalFailed:
            .normal

        case .parallelStarted,
             .parallelSucceeded,
             .parallelCancelled,
             .parallelFailed,
             .signalArmed,
             .signalResultReplayed,
             .signalDuplicateResolutionIgnored:
            .trace
        }
    }

    var message: String {
        let trace = HajimeLogTrace.id.map { "[\($0)]" } ?? ""

        return switch self {
        case let .bootStarted(
            stepCount,
            parallelGroupCount,
            nonBlockingStepCount
        ):
            "[boot]\(trace) → started | steps=\(stepCount) parallel_groups=\(parallelGroupCount) non_blocking_steps=\(nonBlockingStepCount)"
        case .bootSucceeded:
            "[boot]\(trace) ✓ completed"
        case .bootCancelled:
            "[boot]\(trace) • cancelled"
        case let .bootFailed(error):
            "[boot]\(trace) ✗ failed | error=\(error.hajimeTypeDescription)"
        case let .stepStarted(name, priority):
            "[step]\(trace) → started | step=\(name.debugDescription) priority=\(priority.hajimeDescription)"
        case let .stepSucceeded(name):
            "[step]\(trace) ✓ completed | step=\(name.debugDescription)"
        case let .stepCancelled(name):
            "[step]\(trace) • cancelled | step=\(name.debugDescription)"
        case let .stepFailed(name, error):
            "[step]\(trace) ✗ failed | step=\(name.debugDescription) error=\(error.hajimeTypeDescription)"
        case let .stepBecameNonBlocking(name, duration):
            "[step]\(trace) ↗ released readiness | step=\(name.debugDescription) after=\(duration?.hajimeDescription ?? "immediate")"
        case let .parallelStarted(childCount):
            "[parallel]\(trace) → started | children=\(childCount)"
        case let .parallelSucceeded(childCount):
            "[parallel]\(trace) ✓ completed | children=\(childCount)"
        case let .parallelCancelled(childCount):
            "[parallel]\(trace) • cancelled | children=\(childCount)"
        case let .parallelFailed(childCount, error):
            "[parallel]\(trace) ✗ failed | children=\(childCount) error=\(error.hajimeTypeDescription)"
        case let .signalWaitRequested(name):
            "[signal]\(trace) ⏳ waiting | signal=\(name.debugDescription)"
        case let .signalWaitCancelled(name):
            "[signal]\(trace) • wait cancelled | signal=\(name.debugDescription)"
        case let .signalSucceeded(name):
            "[signal]\(trace) ✓ succeeded | signal=\(name.debugDescription)"
        case let .signalFailed(name, error):
            "[signal]\(trace) ✗ failed | signal=\(name.debugDescription) error=\(error.hajimeTypeDescription)"
        case let .signalArmed(name, replacedRun):
            if replacedRun {
                "[signal]\(trace) ↻ rearmed | signal=\(name.debugDescription)"
            } else {
                "[signal]\(trace) → armed | signal=\(name.debugDescription)"
            }
        case let .signalResultReplayed(name):
            "[signal]\(trace) ← replayed stored result | signal=\(name.debugDescription)"
        case let .signalDuplicateResolutionIgnored(name):
            "[signal]\(trace) ⊘ duplicate resolution ignored | signal=\(name.debugDescription)"
        }
    }
}

enum HajimeWarning {
    case signalConfigurationFailure(BootSignalError)

    var message: String {
        switch self {
        case .signalConfigurationFailure(.notRegistered(let signal)):
            "[signal] ⚠︎ not registered with the current bootstrap; declare it with BootStep.waiting(for:) | signal=\(signal.debugDescription)"
        case .signalConfigurationFailure(
            .registeredToAnotherBootstrap(let signal)
        ):
            "[signal] ⚠︎ already registered with another bootstrap | signal=\(signal.debugDescription)"
        }
    }
}

extension Logger {
    func hajimeDebug(_ event: @autoclosure () -> HajimeLogEvent) {
#if DEBUG
        let configuredLevel = Hajime.debug
        guard configuredLevel != .off else { return }

        let event = event()
        guard configuredLevel.includes(event.logLevel) else { return }
        debug("\(event.message, privacy: .public)")
#endif
    }

    func hajimeWarning(_ event: @autoclosure () -> HajimeWarning) {
        let message = event().message
        warning("\(message, privacy: .public)")
    }
}

extension Hajime.DebugLogLevel {
    func includes(_ eventLevel: Self) -> Bool {
        switch (self, eventLevel) {
        case (.trace, _), (.normal, .normal), (.off, .off):
            true
        default:
            false
        }
    }
}

extension TaskPriority {
    var hajimeDescription: String {
        if self == .userInitiated { return "user_initiated" }
        if self == .medium { return "medium" }
        if self == .utility { return "utility" }
        if self == .background { return "background" }
        if rawValue == 0 { return "unspecified" }
        return "raw_\(rawValue)"
    }
}

extension Error {
    var hajimeTypeDescription: String {
        String(describing: type(of: self))
    }
}

private extension Duration {
    var hajimeDescription: String {
        let components = self.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        return String(format: "%.3fs", seconds)
    }
}
