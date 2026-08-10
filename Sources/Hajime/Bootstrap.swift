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

/// Owns one replaceable execution of an immutable application boot plan.
///
/// Call ``start()`` to begin booting and ``waitUntilReady()`` wherever work must
/// suspend until the current execution succeeds. Starting again cancels and
/// supersedes the previous execution. Existing readiness waiters follow the
/// replacement execution. Releasing the coordinator requests cancellation of
/// its current readiness chain and outstanding non-blocking steps.
public final class Bootstrap: Sendable {
    /// The current lifecycle state of a bootstrap coordinator.
    public enum State: Equatable, Sendable {
        /// No execution has been started.
        case idle

        /// The current execution is running its boot plan.
        case booting

        /// The current execution completed successfully.
        case ready

        /// The current execution ended because a boot step threw an error.
        case failed

        /// The current execution ended with cancellation.
        case cancelled
    }

    private let plan: BootPlan
    private let signalBindings: [any BootSignalBinding]
    private let name: String
    private let instrumentation: BootInstrumentation
    private let ownerID = UUID()
    private let coordinator = BootstrapCoordinator()
    private let startLock = OSAllocatedUnfairLock(initialState: ())

    /// Creates a bootstrap coordinator from inline boot declarations.
    ///
    /// - Parameters:
    ///   - name: A stable diagnostic name that contains no sensitive values.
    ///   - instrumentation: The performance measurements to emit. Instruments
    ///     signposts are enabled by default.
    ///   - content: The declarations that make up the boot plan.
    public init(
        _ name: String = "application",
        instrumentation: BootInstrumentation = .automatic,
        @BootPlanBuilder _ content: () -> BootPlan
    ) {
        let plan = content()
        self.plan = plan
        signalBindings = plan.signalBindings
        self.name = name
        self.instrumentation = instrumentation
    }

    /// Creates a bootstrap coordinator from a reusable plan.
    ///
    /// - Parameters:
    ///   - name: A stable diagnostic name that contains no sensitive values.
    ///   - instrumentation: The performance measurements to emit. Instruments
    ///     signposts are enabled by default.
    ///   - plan: The immutable plan to execute.
    public init(
        _ name: String = "application",
        instrumentation: BootInstrumentation = .automatic,
        plan: BootPlan
    ) {
        self.plan = plan
        signalBindings = plan.signalBindings
        self.name = name
        self.instrumentation = instrumentation
    }

    deinit {
        cancelExecution()
    }

    /// The lifecycle state of the current execution.
    ///
    /// This snapshot is safe to read from any isolation domain. Use
    /// ``waitUntilReady()`` instead when subsequent work requires readiness.
    public var state: State {
        coordinator.state
    }

    /// Whether the current execution completed successfully.
    ///
    /// This snapshot is intended for presentation and diagnostics. Use
    /// ``waitUntilReady()`` for control flow that must suspend until readiness.
    public var isReady: Bool {
        state == .ready
    }

    var hasOutstandingNonBlockingSteps: Bool {
        coordinator.hasOutstandingNonBlockingSteps
    }

    /// Starts the boot plan and supersedes any current execution.
    ///
    /// The method returns after scheduling the plan, not after the application
    /// becomes ready. If another execution is running, Hajime requests its
    /// cancellation. Existing ``waitUntilReady()`` calls continue waiting for
    /// this replacement execution. The replacement waits for the superseded
    /// readiness chain to finish cooperative cancellation before its plan
    /// begins. Signals declared through ``BootStep/waiting(for:)`` are then
    /// rearmed for the replacement run. Outstanding steps configured through
    /// ``BootStep/nonBlocking()`` or ``BootStep/nonBlocking(after:)`` receive
    /// cancellation but do not delay the replacement.
    public func start() {
        startLock.withLock {
            startExecution()
        }
    }

    /// Suspends until the current boot execution is ready.
    ///
    /// If no execution has started, the call remains suspended until ``start()``
    /// begins one. Multiple callers may wait concurrently. Starting a replacement
    /// execution keeps existing callers suspended for the replacement. Cancelling
    /// one waiting task cancels only that wait and does not cancel application
    /// boot.
    ///
    /// - Throws: The error that ended the current execution, or
    ///   `CancellationError` when either the execution or this waiting task is
    ///   cancelled.
    public func waitUntilReady() async throws {
        let waiterID = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.addWaiter(
                    id: waiterID,
                    continuation: continuation
                )

                if Task.isCancelled {
                    coordinator.cancelWaiter(id: waiterID)
                }
            }
        } onCancel: {
            coordinator.cancelWaiter(id: waiterID)
        }
    }

    /// Cancels the current execution and its non-blocking steps.
    ///
    /// Before readiness, this also cancels all readiness waiters and transitions
    /// the coordinator to ``State/cancelled``. After readiness, the ready state
    /// remains unchanged while outstanding non-blocking steps receive
    /// cancellation. Boot-step cancellation remains cooperative. Calling
    /// ``start()`` afterward begins a new execution.
    public func cancel() {
        cancelExecution()
    }

    /// Starts the plan and returns after the current execution becomes ready.
    ///
    /// This is a convenience for callers that own the complete boot lifetime.
    /// Cancelling the calling task cancels the shared execution. Use ``start()``
    /// with ``waitUntilReady()`` when waiter cancellation must not stop boot.
    ///
    /// - Throws: An error thrown by a boot step, including cancellation.
    public func run() async throws {
        start()

        try await withTaskCancellationHandler {
            try await waitUntilReady()
        } onCancel: {
            cancel()
        }
    }

    private func startExecution() {
        let preparation = coordinator.prepareForStart(
            name: name,
            instrumentation: instrumentation
        )
        preparation.supersededTask?.cancel()
        preparation.supersededContext?.cancelNonBlockingSteps()
        if let generation = preparation.supersededGeneration {
            let run = BootSignalRun(ownerID: ownerID, generation: generation)
            signalBindings.forEach { $0.cancel(run: run) }
        }

        let task = Task {
            [plan, signalBindings, ownerID, coordinator,
             context = preparation.context] in
            let result: Result<Void, any Error>
            let run = BootSignalRun(
                ownerID: ownerID,
                generation: preparation.generation
            )

            do {
                await preparation.supersededTask?.value
                try Task.checkCancellation()
                context.instrumentation.executionStarted()
                try await BootSignalRuntime.$currentRun.withValue(run) {
                    try await Self.execute(
                        plan,
                        context: context,
                        signals: signalBindings,
                        run: run
                    )
                }
                result = .success(())
            } catch {
                context.cancelNonBlockingSteps()
                signalBindings.forEach { $0.cancel(run: run) }
                result = .failure(error)
            }

            context.instrumentation.finish(result)
            coordinator.finish(
                generation: preparation.generation,
                result: result
            )
        }

        coordinator.install(
            task,
            generation: preparation.generation
        )
    }

    private func cancelExecution() {
        let cancellation = coordinator.cancel()
        cancellation.task?.cancel()
        cancellation.context?.cancelNonBlockingSteps()
        if let generation = cancellation.generation {
            let run = BootSignalRun(ownerID: ownerID, generation: generation)
            signalBindings.forEach { $0.cancel(run: run) }
        }
        cancellation.waiters.forEach {
            $0.resume(throwing: CancellationError())
        }
    }

    private static func execute(
        _ plan: BootPlan,
        context: BootExecutionContext,
        signals: [any BootSignalBinding],
        run: BootSignalRun
    ) async throws {
        try await HajimeLogTrace.withNewID {
            hajimeLog.hajimeDebug(
                .bootStarted(
                    stepCount: plan.stepCount,
                    parallelGroupCount: plan.parallelGroupCount,
                    nonBlockingStepCount: plan.nonBlockingStepCount
                )
            )

            do {
                for signal in signals {
                    try signal.arm(for: run)
                }
                try await plan.execute(context: context)
                hajimeLog.hajimeDebug(.bootSucceeded)
            } catch is CancellationError {
                hajimeLog.hajimeDebug(.bootCancelled)
                throw CancellationError()
            } catch {
                hajimeLog.hajimeDebug(.bootFailed(error: error))
                throw error
            }
        }
    }
}

private final class BootstrapCoordinator: Sendable {
    typealias Waiter = CheckedContinuation<Void, any Error>

    struct Preparation {
        let generation: UInt64
        let supersededGeneration: UInt64?
        let supersededTask: Task<Void, Never>?
        let supersededContext: BootExecutionContext?
        let context: BootExecutionContext
    }

    struct Cancellation {
        let generation: UInt64?
        let task: Task<Void, Never>?
        let context: BootExecutionContext?
        let waiters: [Waiter]
    }

    private struct Storage {
        var generation: UInt64 = 0
        var attempt: UInt64 = 0
        var state = Bootstrap.State.idle
        var result: Result<Void, any Error>?
        var task: Task<Void, Never>?
        var context: BootExecutionContext?
        var waiters: [UUID: Waiter] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    var state: Bootstrap.State {
        lock.withLock { $0.state }
    }

    var hasOutstandingNonBlockingSteps: Bool {
        lock.withLock { $0.context?.hasNonBlockingSteps == true }
    }

    func prepareForStart(
        name: String,
        instrumentation: BootInstrumentation
    ) -> Preparation {
        lock.withLock { storage in
            let supersededGeneration = storage.generation == 0
                ? nil
                : storage.generation
            storage.generation &+= 1
            storage.attempt &+= 1
            let supersededTask = storage.task
            let supersededContext = storage.context
            let context = BootExecutionContext(
                instrumentation: BootRunInstrumentation(
                    bootstrap: name,
                    attempt: storage.attempt,
                    configuration: instrumentation
                )
            )
            storage.state = .booting
            storage.result = nil
            storage.task = nil
            storage.context = context
            return Preparation(
                generation: storage.generation,
                supersededGeneration: supersededGeneration,
                supersededTask: supersededTask,
                supersededContext: supersededContext,
                context: context
            )
        }
    }

    func install(_ task: Task<Void, Never>, generation: UInt64) {
        let isCurrent = lock.withLock { storage in
            guard storage.generation == generation,
                  storage.result == nil
            else { return false }
            storage.task = task
            return true
        }

        if !isCurrent {
            task.cancel()
        }
    }

    func finish(
        generation: UInt64,
        result: Result<Void, any Error>
    ) {
        let waiters: [Waiter]? = lock.withLock { storage in
            guard storage.generation == generation else { return nil }

            storage.state = switch result {
            case .success:
                .ready
            case .failure(let error) where error is CancellationError:
                .cancelled
            case .failure:
                .failed
            }
            storage.result = result
            storage.task = nil

            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return waiters
        }

        waiters?.forEach { $0.resume(with: result) }
    }

    func addWaiter(id: UUID, continuation: Waiter) {
        let result: Result<Void, any Error>? = lock.withLock { storage in
            if let result = storage.result {
                return result
            }

            storage.waiters[id] = continuation
            return nil
        }

        if let result {
            continuation.resume(with: result)
        }
    }

    func cancelWaiter(id: UUID) {
        let waiter = lock.withLock { storage in
            storage.waiters.removeValue(forKey: id)
        }
        waiter?.resume(throwing: CancellationError())
    }

    func cancel() -> Cancellation {
        lock.withLock { storage in
            guard storage.state == .idle || storage.state == .booting else {
                return Cancellation(
                    generation: storage.generation == 0
                        ? nil
                        : storage.generation,
                    task: nil,
                    context: storage.context,
                    waiters: []
                )
            }

            let cancelledGeneration = storage.generation == 0
                ? nil
                : storage.generation
            storage.generation &+= 1
            storage.state = .cancelled
            storage.result = .failure(CancellationError())

            let cancellation = Cancellation(
                generation: cancelledGeneration,
                task: storage.task,
                context: storage.context,
                waiters: Array(storage.waiters.values)
            )
            storage.task = nil
            storage.context = nil
            storage.waiters.removeAll()
            return cancellation
        }
    }
}

final class BootExecutionContext: Sendable {
    typealias StepResult = Result<Void, any Error>

    private struct Storage {
        var isCancelled = false
        var nextStepID: UInt64 = 0
        var nonBlockingSteps: [UInt64: NonBlockingStepTask] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())
    let instrumentation: BootRunInstrumentation

    init(instrumentation: BootRunInstrumentation) {
        self.instrumentation = instrumentation
    }

    var hasNonBlockingSteps: Bool {
        lock.withLock { !$0.nonBlockingSteps.isEmpty }
    }

    func execute(_ step: BootStep) async throws {
        switch step.readiness {
        case .required:
            let task = makeTask(for: step)
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            try result.get()

        case .nonBlocking:
            let task = makeTask(for: step)
            try adopt(
                task,
                step: step.name,
                priority: step.priority
            )
            hajimeLog.hajimeDebug(
                .stepBecameNonBlocking(name: step.name, after: nil)
            )
            try Task.checkCancellation()

        case .nonBlockingAfter(let duration):
            try await execute(step, nonBlockingAfter: duration)
        }
    }

    func cancelNonBlockingSteps() {
        let steps = lock.withLock { storage in
            storage.isCancelled = true
            return Array(storage.nonBlockingSteps.values)
        }

        steps.forEach { $0.cancel() }
    }

    private func execute(
        _ step: BootStep,
        nonBlockingAfter duration: Duration
    ) async throws {
        let race = BootStepReadinessRace()
        let budgetSpan = instrumentation.start(
            .readinessBudget(step: step.name)
        )
        let task = makeTask(for: step, race: race)
        let deadline = Task {
            do {
                try await Task.sleep(for: duration)
                race.resolve(.releasedReadiness)
            } catch {
                race.resolve(.cancelled)
            }
        }

        let decision = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            task.cancel()
            deadline.cancel()
        }
        budgetSpan?.finish(decision.instrumentationOutcome)

        switch decision {
        case .completed(let result):
            deadline.cancel()
            try Task.checkCancellation()
            try result.get()

        case .releasedReadiness:
            try adopt(
                task,
                step: step.name,
                priority: step.priority
            )
            hajimeLog.hajimeDebug(
                .stepBecameNonBlocking(
                    name: step.name,
                    after: duration
                )
            )
            try Task.checkCancellation()

        case .cancelled:
            task.cancel()
            _ = await task.value
            throw CancellationError()
        }
    }

    private func makeTask(
        for step: BootStep,
        race: BootStepReadinessRace? = nil
    ) -> Task<StepResult, Never> {
        Task(priority: step.priority) { [self] in
            let result = await executeWork(of: step)
            race?.resolve(.completed(result))
            return result
        }
    }

    private func executeWork(of step: BootStep) async -> StepResult {
        do {
            try await instrumentation.measure(
                .step(name: step.name, priority: step.priority)
            ) {
                hajimeLog.hajimeDebug(
                    .stepStarted(name: step.name, priority: step.priority)
                )

                do {
                    try await step.executeWork(context: self)
                    try Task.checkCancellation()
                    hajimeLog.hajimeDebug(.stepSucceeded(name: step.name))
                } catch is CancellationError {
                    hajimeLog.hajimeDebug(.stepCancelled(name: step.name))
                    throw CancellationError()
                } catch {
                    hajimeLog.hajimeDebug(
                        .stepFailed(name: step.name, error: error)
                    )
                    throw error
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func adopt(
        _ work: Task<StepResult, Never>,
        step: String,
        priority: TaskPriority
    ) throws {
        let trackedStep = NonBlockingStepTask(work: work)
        let stepID: UInt64? = lock.withLock { storage in
            guard !storage.isCancelled else { return nil }

            storage.nextStepID &+= 1
            storage.nonBlockingSteps[storage.nextStepID] = trackedStep
            return storage.nextStepID
        }

        guard let stepID else {
            work.cancel()
            throw CancellationError()
        }

        let nonBlockingSpan = instrumentation.start(
            .nonBlocking(step: step)
        )
        Task(priority: priority) { [self] in
            let result = await work.value
            nonBlockingSpan?.finish(.init(result))
            finishNonBlockingStep(stepID)
        }
    }

    private func finishNonBlockingStep(_ id: UInt64) {
        _ = lock.withLock { storage in
            storage.nonBlockingSteps.removeValue(forKey: id)
        }
    }
}

private enum BootStepReadinessDecision: Sendable {
    case completed(BootExecutionContext.StepResult)
    case releasedReadiness
    case cancelled

    var instrumentationOutcome: BootInstrumentation.Measurement.Outcome {
        switch self {
        case .completed(let result):
            .init(result)
        case .releasedReadiness:
            .releasedReadiness
        case .cancelled:
            .cancelled
        }
    }
}

private final class BootStepReadinessRace: Sendable {
    typealias Decision = BootStepReadinessDecision
    typealias Waiter = CheckedContinuation<Decision, Never>

    private struct Storage {
        var decision: Decision?
        var waiter: Waiter?
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    func wait() async -> Decision {
        await withCheckedContinuation { continuation in
            let decision: Decision? = lock.withLock { storage in
                if let decision = storage.decision {
                    return decision
                }

                storage.waiter = continuation
                return nil
            }

            if let decision {
                continuation.resume(returning: decision)
            }
        }
    }

    func resolve(_ decision: Decision) {
        let waiter: Waiter? = lock.withLock { storage in
            guard storage.decision == nil else { return nil }
            storage.decision = decision
            let waiter = storage.waiter
            storage.waiter = nil
            return waiter
        }

        waiter?.resume(returning: decision)
    }
}

private final class NonBlockingStepTask: Sendable {
    typealias StepResult = BootExecutionContext.StepResult

    private let work: Task<StepResult, Never>

    init(work: Task<StepResult, Never>) {
        self.work = work
    }

    func cancel() {
        work.cancel()
    }
}
