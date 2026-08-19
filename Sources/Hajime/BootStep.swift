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

/// One named asynchronous operation in a ``BootPlan``.
///
/// A step runs when execution reaches its declaration. Steps declared next to
/// each other run sequentially unless they are nested in ``Parallel``. Signal
/// requirements added through ``waiting(for:)`` begin concurrently after the
/// operation and extend the step until every requirement finishes.
public struct BootStep: Sendable {
    let name: String
    let priority: TaskPriority
    let operation: @isolated(any) @Sendable () async throws -> Void
    var waitRequirements: [BootWaitRequirement]
    var readiness: BootStepReadiness
    var progressID: BootProgress.ID?

    /// Creates a named boot step from an asynchronous operation.
    ///
    /// The operation may inherit actor isolation from its declaration. Throwing
    /// an error stops the surrounding sequential plan. Inside ``Parallel``, the
    /// error also requests cancellation of unfinished sibling operations.
    ///
    /// - Parameters:
    ///   - name: A stable diagnostic name that contains no sensitive values.
    ///   - priority: The requested operation priority. The default is
    ///     `userInitiated` because the step blocks work needed for immediate app
    ///     use.
    ///   - operation: The work to perform when execution reaches the step.
    public init(
        _ name: String,
        priority: TaskPriority = .userInitiated,
        operation: @isolated(any) @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.priority = priority
        self.operation = operation
        waitRequirements = []
        readiness = .required
        progressID = nil
    }

    /// Extends this step until a signal resolves successfully.
    ///
    /// Hajime runs the step's operation first, then waits for the signal. The
    /// step completes only after the signal succeeds. A signal failure fails the
    /// step. Chaining this modifier adds independent requirements that Hajime
    /// waits for concurrently.
    ///
    /// - Parameter signal: The callback bridge that completes this requirement.
    /// - Returns: A step that waits for `signal` after running its operation.
    public func waiting<Value: Sendable>(
        for signal: BootSignal<Value>
    ) -> BootStep {
        appending(
            BootWaitRequirement(signals: [signal]) { step, instrumentation in
                _ = try await BootWaitRequirement.wait(
                    for: signal,
                    step: step,
                    instrumentation: instrumentation
                )
            }
        )
    }

    /// Extends this step through signal resolution and result handling.
    ///
    /// Hajime runs the step's operation first, waits for the signal, and then
    /// invokes `completion` with its value. The step completes only after the
    /// completion operation returns. A signal or completion failure fails the
    /// step. Chained requirements wait and handle their results concurrently.
    /// The completion may inherit actor isolation from its declaration and runs
    /// as part of this step's requested priority.
    ///
    /// - Parameters:
    ///   - signal: The callback bridge that supplies the completion value.
    ///   - completion: The work to perform after the signal succeeds.
    /// - Returns: A step extended through signal resolution and result handling.
    public func waiting<Value: Sendable>(
        for signal: BootSignal<Value>,
        then completion: @isolated(any) @escaping @Sendable (Value) async throws -> Void
    ) -> BootStep {
        appending(
            BootWaitRequirement(signals: [signal]) { step, instrumentation in
                let value = try await BootWaitRequirement.wait(
                    for: signal,
                    step: step,
                    instrumentation: instrumentation
                )
                try await BootWaitRequirement.handle(
                    signals: [signal.diagnosticName],
                    step: step,
                    instrumentation: instrumentation
                ) {
                    try await completion(value)
                }
            }
        )
    }

    /// Extends this step through the successful resolution of two signals.
    ///
    /// Hajime waits for both signals concurrently after running the step's
    /// operation, then invokes `completion` once with both resolved values. The
    /// step completes only after that operation returns. Any signal or completion
    /// failure fails the step.
    ///
    /// - Parameters:
    ///   - first: The first callback bridge to await.
    ///   - second: The second callback bridge to await.
    ///   - completion: The work to perform after both signals succeed.
    /// - Returns: A step extended through both resolutions and result handling.
    public func waiting<First: Sendable, Second: Sendable>(
        for first: BootSignal<First>,
        _ second: BootSignal<Second>,
        then completion: @isolated(any) @escaping @Sendable (First, Second) async throws -> Void
    ) -> BootStep {
        appending(
            BootWaitRequirement(
                signals: [first, second]
            ) { step, instrumentation in
                async let firstValue = BootWaitRequirement.wait(
                    for: first,
                    step: step,
                    instrumentation: instrumentation
                )
                async let secondValue = BootWaitRequirement.wait(
                    for: second,
                    step: step,
                    instrumentation: instrumentation
                )
                let values = try await (firstValue, secondValue)
                try await BootWaitRequirement.handle(
                    signals: [first.diagnosticName, second.diagnosticName],
                    step: step,
                    instrumentation: instrumentation
                ) {
                    try await completion(values.0, values.1)
                }
            }
        )
    }

    /// Extends this step through the successful resolution of three signals.
    ///
    /// Hajime waits for all signals concurrently after running the step's
    /// operation, then invokes `completion` once with their resolved values. The
    /// step completes only after that operation returns. Any signal or completion
    /// failure fails the step.
    ///
    /// - Parameters:
    ///   - first: The first callback bridge to await.
    ///   - second: The second callback bridge to await.
    ///   - third: The third callback bridge to await.
    ///   - completion: The work to perform after every signal succeeds.
    /// - Returns: A step extended through all resolutions and result handling.
    public func waiting<
        First: Sendable,
        Second: Sendable,
        Third: Sendable
    >(
        for first: BootSignal<First>,
        _ second: BootSignal<Second>,
        _ third: BootSignal<Third>,
        then completion: @isolated(any) @escaping @Sendable (First, Second, Third) async throws -> Void
    ) -> BootStep {
        appending(
            BootWaitRequirement(
                signals: [first, second, third]
            ) { step, instrumentation in
                async let firstValue = BootWaitRequirement.wait(
                    for: first,
                    step: step,
                    instrumentation: instrumentation
                )
                async let secondValue = BootWaitRequirement.wait(
                    for: second,
                    step: step,
                    instrumentation: instrumentation
                )
                async let thirdValue = BootWaitRequirement.wait(
                    for: third,
                    step: step,
                    instrumentation: instrumentation
                )
                let values = try await (
                    firstValue,
                    secondValue,
                    thirdValue
                )
                try await BootWaitRequirement.handle(
                    signals: [
                        first.diagnosticName,
                        second.diagnosticName,
                        third.diagnosticName,
                    ],
                    step: step,
                    instrumentation: instrumentation
                ) {
                    try await completion(values.0, values.1, values.2)
                }
            }
        )
    }

    /// Allows this step to continue independently of application readiness.
    ///
    /// Hajime starts the complete step when execution reaches its declaration,
    /// then immediately continues the surrounding plan. The operation, signal
    /// waits, and signal handlers remain owned by the ``Bootstrap`` and receive
    /// cancellation when it is cancelled, replaced, or deallocated. A later
    /// failure is contained and does not change readiness.
    ///
    /// This modifier does not change the step's task priority. Applying it
    /// before or after ``waiting(for:)`` produces the same behavior.
    ///
    /// - Returns: A step that does not delay application readiness.
    public func nonBlocking() -> BootStep {
        settingReadiness(.nonBlocking)
    }

    /// Allows this step to stop delaying readiness after a duration.
    ///
    /// Before `duration` elapses, completion and failure behave like an
    /// ordinary blocking step. If the complete step is still running when the
    /// duration elapses, Hajime continues the surrounding plan while the same
    /// operation, signal waits, and signal handlers remain running under the
    /// ``Bootstrap``. A failure after that transition is contained.
    ///
    /// The transition does not cancel, restart, or reprioritize the step. A
    /// non-positive duration behaves like ``nonBlocking()``. Applying this
    /// modifier before or after ``waiting(for:)`` produces the same behavior.
    ///
    /// - Parameter duration: How long the step may delay readiness.
    /// - Returns: A step with a bounded readiness contribution.
    public func nonBlocking(after duration: Duration) -> BootStep {
        guard duration > .zero else { return nonBlocking() }
        return settingReadiness(.nonBlockingAfter(duration))
    }

    func executeWork(context: BootExecutionContext) async throws {
        try await context.instrumentation.measure(
            .operation(step: name)
        ) {
            try await operation()
        }
        try Task.checkCancellation()

        try await executeConcurrently(waitRequirements) { requirement in
            try await requirement.execute(
                step: name,
                instrumentation: context.instrumentation
            )
        }
        try Task.checkCancellation()
    }

    private func settingReadiness(_ readiness: BootStepReadiness) -> BootStep {
        var copy = self
        copy.readiness = readiness
        return copy
    }

    private func appending(_ requirement: BootWaitRequirement) -> BootStep {
        var copy = self
        copy.waitRequirements.append(requirement)
        return copy
    }
}

enum BootStepReadiness: Equatable, Sendable {
    case required
    case nonBlocking
    case nonBlockingAfter(Duration)

    var mayReleaseReadiness: Bool {
        switch self {
        case .required:
            false
        case .nonBlocking, .nonBlockingAfter:
            true
        }
    }
}

struct BootWaitRequirement: Sendable {
    let signals: [any BootSignalBinding]
    private let operation:
        @Sendable (String, BootRunInstrumentation) async throws -> Void

    init(
        signals: [any BootSignalBinding],
        operation: @escaping @Sendable (
            String,
            BootRunInstrumentation
        ) async throws -> Void
    ) {
        self.signals = signals
        self.operation = operation
    }

    func execute(
        step: String,
        instrumentation: BootRunInstrumentation
    ) async throws {
        try await operation(step, instrumentation)
    }

    static func wait<Value: Sendable>(
        for signal: BootSignal<Value>,
        step: String,
        instrumentation: BootRunInstrumentation
    ) async throws -> Value {
        try await instrumentation.measure(
            .signalWait(signal: signal.diagnosticName, step: step)
        ) {
            try await signal.wait()
        }
    }

    static func handle(
        signals: [String],
        step: String,
        instrumentation: BootRunInstrumentation,
        operation: @isolated(any) () async throws -> Void
    ) async throws {
        try await instrumentation.measure(
            .signalHandler(signals: signals, step: step)
        ) {
            try await operation()
        }
    }
}
