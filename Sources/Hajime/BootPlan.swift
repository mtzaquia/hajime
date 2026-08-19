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

/// An immutable sequence of boot declarations.
///
/// Declarations at the same level execute sequentially in source order. A plan
/// can be extracted and embedded in another plan to keep larger boot flows
/// organized.
public struct BootPlan: Sendable {
    fileprivate let nodes: [BootPlanNode]

    /// Creates a plan from boot steps, parallel groups, and nested plans.
    ///
    /// - Parameter content: The declarations that make up the plan.
    public init(@BootPlanBuilder _ content: () -> BootPlan) {
        self = content()
    }

    fileprivate init(nodes: [BootPlanNode] = []) {
        self.nodes = nodes
    }
}

/// A group whose direct child declarations begin concurrently.
///
/// Execution leaves the group after every child either succeeds or releases
/// readiness through ``BootStep/nonBlocking()`` or
/// ``BootStep/nonBlocking(after:)``. When a child fails before releasing
/// readiness, the group requests cancellation of its unfinished siblings and
/// propagates the error to the surrounding plan.
public struct Parallel: Sendable {
    fileprivate let plan: BootPlan

    /// Creates a parallel group from boot steps and nested plans.
    ///
    /// - Parameter content: The declarations to begin concurrently.
    public init(@BootPlanBuilder _ content: () -> BootPlan) {
        plan = content()
    }
}

/// Builds an immutable ``BootPlan`` from sequential declarations.
///
/// Use this builder through ``Bootstrap/init(_:)``, ``BootPlan/init(_:)``,
/// or ``Parallel/init(_:)`` rather than invoking its methods directly.
@resultBuilder
public enum BootPlanBuilder {
    /// Combines declarations into one sequential plan.
    public static func buildBlock(_ components: BootPlan...) -> BootPlan {
        BootPlan(nodes: components.flatMap(\.nodes))
    }

    /// Adds one boot step to a plan.
    public static func buildExpression(_ expression: BootStep) -> BootPlan {
        BootPlan(nodes: [.step(expression)])
    }

    /// Adds one parallel group to a plan.
    public static func buildExpression(_ expression: Parallel) -> BootPlan {
        BootPlan(nodes: [.parallel(expression.plan.nodes)])
    }

    /// Embeds an existing plan in the surrounding sequence.
    public static func buildExpression(_ expression: BootPlan) -> BootPlan {
        BootPlan(nodes: [.sequence(expression.nodes)])
    }

    /// Includes a conditionally declared plan when its condition is true.
    public static func buildOptional(_ component: BootPlan?) -> BootPlan {
        component ?? BootPlan()
    }

    /// Selects the first branch of a conditional declaration.
    public static func buildEither(first component: BootPlan) -> BootPlan {
        component
    }

    /// Selects the second branch of a conditional declaration.
    public static func buildEither(second component: BootPlan) -> BootPlan {
        component
    }

    /// Combines plans produced by a loop in iteration order.
    public static func buildArray(_ components: [BootPlan]) -> BootPlan {
        BootPlan(nodes: components.flatMap(\.nodes))
    }

    /// Preserves declarations guarded by an availability check.
    public static func buildLimitedAvailability(_ component: BootPlan) -> BootPlan {
        component
    }
}

fileprivate indirect enum BootPlanNode: Sendable {
    case step(BootStep)
    case sequence([BootPlanNode])
    case parallel([BootPlanNode])

    func execute(context: BootExecutionContext) async throws {
        try Task.checkCancellation()

        switch self {
        case .step(let step):
            try await context.execute(step)

        case .sequence(let nodes):
            for node in nodes {
                try await node.execute(context: context)
            }

        case .parallel(let nodes):
            try await context.instrumentation.measure(.parallel) {
                hajimeLog.hajimeDebug(
                    .parallelStarted(childCount: nodes.count)
                )

                do {
                    try await executeConcurrently(nodes) { node in
                        try await node.execute(context: context)
                    }
                    hajimeLog.hajimeDebug(
                        .parallelSucceeded(childCount: nodes.count)
                    )
                } catch is CancellationError {
                    hajimeLog.hajimeDebug(
                        .parallelCancelled(childCount: nodes.count)
                    )
                    throw CancellationError()
                } catch {
                    hajimeLog.hajimeDebug(
                        .parallelFailed(
                            childCount: nodes.count,
                            error: error
                        )
                    )
                    throw error
                }
            }
        }
    }
}

extension BootPlan {
    func assigningProgressIDs() -> BootPlan {
        BootPlan(nodes: nodes.map { $0.assigningProgressIDs() })
    }

    var stepCount: Int {
        nodes.reduce(0) { $0 + $1.stepCount }
    }

    var parallelGroupCount: Int {
        nodes.reduce(0) { $0 + $1.parallelGroupCount }
    }

    var nonBlockingStepCount: Int {
        nodes.reduce(0) { $0 + $1.nonBlockingStepCount }
    }

    var signalBindings: [any BootSignalBinding] {
        var identities: Set<ObjectIdentifier> = []
        return nodes
            .flatMap(\.signalBindings)
            .filter { identities.insert($0.identity).inserted }
    }

    func execute(context: BootExecutionContext) async throws {
        try await BootPlanNode.sequence(nodes).execute(context: context)
    }
}

func executeConcurrently<Element: Sendable>(
    _ elements: [Element],
    operation: @escaping @Sendable (Element) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for element in elements {
            group.addTask {
                try await operation(element)
            }
        }

        do {
            while let _ = try await group.next() {}
            try Task.checkCancellation()
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

private extension BootPlanNode {
    func assigningProgressIDs() -> BootPlanNode {
        switch self {
        case .step(var step):
            step.progressID = BootProgress.ID()
            return .step(step)
        case .sequence(let nodes):
            return .sequence(nodes.map { $0.assigningProgressIDs() })
        case .parallel(let nodes):
            return .parallel(nodes.map { $0.assigningProgressIDs() })
        }
    }

    var signalBindings: [any BootSignalBinding] {
        switch self {
        case .step(let step):
            step.waitRequirements.flatMap(\.signals)
        case .sequence(let nodes), .parallel(let nodes):
            nodes.flatMap(\.signalBindings)
        }
    }

    var stepCount: Int {
        switch self {
        case .step:
            1
        case .sequence(let nodes), .parallel(let nodes):
            nodes.reduce(0) { $0 + $1.stepCount }
        }
    }

    var parallelGroupCount: Int {
        switch self {
        case .step:
            0
        case .sequence(let nodes):
            nodes.reduce(0) { $0 + $1.parallelGroupCount }
        case .parallel(let nodes):
            1 + nodes.reduce(0) { $0 + $1.parallelGroupCount }
        }
    }

    var nonBlockingStepCount: Int {
        switch self {
        case .step(let step):
            step.readiness.mayReleaseReadiness ? 1 : 0
        case .sequence(let nodes), .parallel(let nodes):
            nodes.reduce(0) { $0 + $1.nonBlockingStepCount }
        }
    }
}
