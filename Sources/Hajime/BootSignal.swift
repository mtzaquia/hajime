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

/// A configuration error encountered while managing a bootstrap signal.
public enum BootSignalError: Error, Equatable, Sendable {
    /// The signal was awaited by a bootstrap that did not declare it through a
    /// ``BootStep/waiting(for:)`` requirement.
    case notRegistered(signal: String)

    /// The signal is already managed by another bootstrap coordinator.
    case registeredToAnotherBootstrap(signal: String)
}

struct BootSignalRun: Equatable, Sendable {
    let ownerID: UUID
    let generation: UInt64
}

enum BootSignalRuntime {
    @TaskLocal static var currentRun: BootSignalRun?
}

protocol BootSignalBinding: AnyObject, Sendable {
    var identity: ObjectIdentifier { get }
    var diagnosticName: String { get }

    func arm(for run: BootSignalRun) throws
    func cancel(run: BootSignalRun)
}

/// A callback bridge that can participate in standalone or managed boot work.
///
/// Used on its own, a signal stores its first success or failure and delivers
/// that result to every current and future waiter. Declaring it through
/// ``BootStep/waiting(for:)`` instead gives the same instance one first-wins
/// resolution per execution of the owning ``Bootstrap``. It remains safe to
/// share across delegates, services, and tasks in either mode.
public final class BootSignal<Value: Sendable>: Sendable {
    private typealias Waiter = CheckedContinuation<Value, any Error>

    private enum Resolution {
        case accepted([Waiter])
        case duplicate
    }

    private struct Storage {
        var ownerID: UUID?
        var activeRun: BootSignalRun?
        var hasManagedRun = false
        var result: Result<Value, any Error>?
        var waiters: [UUID: Waiter] = [:]
    }

    private let name: String
    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    /// Creates an unresolved signal with a diagnostic name.
    ///
    /// Hajime emits `name` as public log text. Use a stable developer-authored
    /// identifier such as `"push-registration"`; never include runtime values,
    /// user data, or sensitive information.
    ///
    /// - Parameter name: The stable identifier used in diagnostics.
    public init(_ name: String) {
        self.name = name
    }

    /// Suspends until the signal receives its success or failure for this use.
    ///
    /// A standalone signal buffers its first result for every future waiter. A
    /// signal declared by ``BootStep/waiting(for:)`` instead buffers one result
    /// per execution of its owning ``Bootstrap`` and is rearmed when that
    /// bootstrap starts again. Multiple callers in the same lifetime receive the
    /// same result. Cancelling one caller removes only that wait.
    ///
    /// Waiting from a boot execution that did not declare this signal fails
    /// immediately with ``BootSignalError/notRegistered(signal:)``. A direct
    /// waiter outside boot execution observes the signal's standalone lifetime
    /// or its currently active managed run.
    ///
    /// - Returns: The value supplied to the first ``succeed(_:)`` or successful
    ///   ``resolve(_:)`` call.
    /// - Throws: The error supplied to the first ``fail(_:)`` or failed
    ///   ``resolve(_:)`` call, or `CancellationError` when this waiter is
    ///   cancelled.
    public func wait() async throws -> Value {
        try Task.checkCancellation()

        let waiterID = UUID()
        hajimeLog.hajimeDebug(.signalWaitRequested(name: name))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let decision: WaitDecision = lock.withLock { storage in
                    if let currentRun = BootSignalRuntime.currentRun {
                        guard let ownerID = storage.ownerID else {
                            return .configurationFailure(
                                .notRegistered(signal: name)
                            )
                        }
                        guard ownerID == currentRun.ownerID else {
                            return .configurationFailure(
                                .registeredToAnotherBootstrap(signal: name)
                            )
                        }
                        guard storage.activeRun == currentRun else {
                            return .cancelled
                        }
                    }

                    if let result = storage.result {
                        return .resolved(result)
                    }

                    storage.waiters[waiterID] = continuation
                    return .waiting
                }

                switch decision {
                case .waiting:
                    break
                case .resolved(let result):
                    hajimeLog.hajimeDebug(.signalResultReplayed(name: name))
                    continuation.resume(with: result)
                case .configurationFailure(let error):
                    hajimeLog.hajimeWarning(
                        .signalConfigurationFailure(error)
                    )
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }

                if Task.isCancelled {
                    cancelWaiter(id: waiterID)
                }
            }
        } onCancel: {
            cancelWaiter(id: waiterID)
        }
    }

    /// Resolves the signal's current lifetime successfully with a value.
    ///
    /// The first resolution in a standalone lifetime or managed bootstrap run
    /// wins. Later calls in that lifetime are harmless and ignored. Fulfillment
    /// is synchronous and may be called from any isolation context.
    ///
    /// - Parameter value: The value delivered to every current and future
    ///   waiter. Hajime diagnostics never inspect or log it.
    public func succeed(_ value: Value) {
        finish(with: .success(value))
    }

    /// Resolves the signal's current lifetime with a failure.
    ///
    /// The first resolution in a standalone lifetime or managed bootstrap run
    /// wins. Later calls in that lifetime are harmless and ignored. Fulfillment
    /// is synchronous and may be called from any isolation context.
    ///
    /// - Parameter error: The error delivered to every current and future
    ///   waiter. Diagnostics log only its concrete type.
    public func fail(_ error: any Error) {
        finish(with: .failure(error))
    }

    /// Resolves the signal's current lifetime from a result.
    ///
    /// The first resolution in a standalone lifetime or managed bootstrap run
    /// wins. Later calls in that lifetime are harmless and ignored. Resolution
    /// is synchronous and may be called from any isolation context.
    ///
    /// - Parameter result: The result delivered to every current and future
    ///   waiter.
    public func resolve<Failure: Error>(
        _ result: Result<Value, Failure>
    ) {
        switch result {
        case .success(let value):
            succeed(value)
        case .failure(let error):
            fail(error)
        }
    }

    var pendingWaiterCount: Int {
        lock.withLock { $0.waiters.count }
    }

    var identity: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    var diagnosticName: String {
        name
    }

    func arm(for run: BootSignalRun) throws {
        let action: ArmAction = lock.withLock { storage in
            if let ownerID = storage.ownerID, ownerID != run.ownerID {
                return .configurationFailure(
                    .registeredToAnotherBootstrap(signal: name)
                )
            }

            storage.ownerID = run.ownerID
            let replacedRun = storage.hasManagedRun
            let waiters: [Waiter]

            if replacedRun {
                waiters = Array(storage.waiters.values)
                storage.waiters.removeAll()
                storage.result = nil
            } else {
                waiters = []
            }

            storage.activeRun = run
            storage.hasManagedRun = true
            return .armed(cancelledWaiters: waiters, replacedRun: replacedRun)
        }

        switch action {
        case let .armed(waiters, replacedRun):
            waiters.forEach {
                $0.resume(throwing: CancellationError())
            }
            hajimeLog.hajimeDebug(
                .signalArmed(name: name, replacedRun: replacedRun)
            )
        case .configurationFailure(let error):
            hajimeLog.hajimeWarning(.signalConfigurationFailure(error))
            throw error
        }
    }

    func cancel(run: BootSignalRun) {
        let waiters: [Waiter] = lock.withLock { storage in
            guard storage.activeRun == run, storage.result == nil else {
                return []
            }

            storage.result = .failure(CancellationError())
            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return waiters
        }

        waiters.forEach {
            $0.resume(throwing: CancellationError())
        }
    }

    private func finish(with result: Result<Value, any Error>) {
        let resolution = lock.withLock { storage in
            guard storage.result == nil else {
                return Resolution.duplicate
            }

            storage.result = result
            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return .accepted(waiters)
        }

        switch resolution {
        case .accepted(let waiters):
            switch result {
            case .success:
                hajimeLog.hajimeDebug(.signalSucceeded(name: name))
            case .failure(let error):
                hajimeLog.hajimeDebug(
                    .signalFailed(name: name, error: error)
                )
            }
            waiters.forEach { $0.resume(with: result) }

        case .duplicate:
            hajimeLog.hajimeDebug(
                .signalDuplicateResolutionIgnored(name: name)
            )
        }
    }

    private func cancelWaiter(id: UUID) {
        let waiter = lock.withLock { storage in
            storage.waiters.removeValue(forKey: id)
        }

        guard let waiter else { return }
        hajimeLog.hajimeDebug(.signalWaitCancelled(name: name))
        waiter.resume(throwing: CancellationError())
    }

    private enum WaitDecision {
        case waiting
        case resolved(Result<Value, any Error>)
        case configurationFailure(BootSignalError)
        case cancelled
    }

    private enum ArmAction {
        case armed(cancelledWaiters: [Waiter], replacedRun: Bool)
        case configurationFailure(BootSignalError)
    }
}

extension BootSignal: BootSignalBinding {}

public extension BootSignal where Value == Void {
    /// Resolves the signal's current lifetime successfully without a value.
    ///
    /// The first resolution in a standalone lifetime or managed bootstrap run
    /// wins. Later calls in that lifetime are harmless and ignored. Fulfillment
    /// is synchronous and may be called from any isolation context.
    func succeed() {
        succeed(())
    }
}
