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

private actor ExecutionTrace {
    private(set) var events: [String] = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func append(_ event: String) {
        events.append(event)
    }

    func begin(_ event: String) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        events.append("\(event)-started")
    }

    func end(_ event: String) {
        events.append("\(event)-finished")
        activeCount -= 1
    }
}

private actor PriorityProbe {
    private var recordedPriority: TaskPriority?
    private var continuation: CheckedContinuation<TaskPriority, Never>?

    func record(_ priority: TaskPriority) {
        recordedPriority = priority
        continuation?.resume(returning: priority)
        continuation = nil
    }

    func next() async -> TaskPriority {
        if let recordedPriority {
            return recordedPriority
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private enum TestFailure: Error {
    case expected
}

@Suite("Boot plan DSL")
struct BootPlanDSLTests {
    @Test("Steps request user-initiated priority by default")
    func requestsUserInitiatedPriorityByDefault() async throws {
        let priority = try await recordedPriority(for: nil)

        #expect(priority == .userInitiated)
    }

    @Test("Steps can request another execution priority")
    func requestsCustomPriority() async throws {
        let priority = try await recordedPriority(for: .utility)

        #expect(priority == .utility)
    }

    @Test("Root steps execute in declaration order")
    func executesRootStepsSequentially() async throws {
        let trace = ExecutionTrace()
        let bootstrap = Bootstrap {
            BootStep("first") {
                await trace.append("first")
            }
            BootStep("second") {
                await trace.append("second")
            }
            BootStep("third") {
                await trace.append("third")
            }
        }

        try await bootstrap.run()

        #expect(await trace.events == ["first", "second", "third"])
    }

    @Test("Parallel children overlap and the surrounding sequence waits")
    func executesParallelChildrenConcurrently() async throws {
        let trace = ExecutionTrace()
        let bootstrap = Bootstrap {
            BootStep("before") {
                await trace.append("before")
            }

            Parallel {
                BootStep("session") {
                    await trace.begin("session")
                    try await Task.sleep(for: .milliseconds(40))
                    await trace.end("session")
                }
                BootStep("configuration") {
                    await trace.begin("configuration")
                    try await Task.sleep(for: .milliseconds(40))
                    await trace.end("configuration")
                }
            }

            BootStep("after") {
                await trace.append("after")
            }
        }

        try await bootstrap.run()

        let events = await trace.events
        #expect(events.first == "before")
        #expect(events.last == "after")
        #expect(await trace.maximumActiveCount == 2)
    }

    @Test("A thrown error skips later sequential steps")
    func stopsSequentialExecutionAfterFailure() async {
        let trace = ExecutionTrace()
        let bootstrap = Bootstrap {
            BootStep("failing") {
                throw TestFailure.expected
            }
            BootStep("skipped") {
                await trace.append("skipped")
            }
        }

        await #expect(throws: TestFailure.self) {
            try await bootstrap.run()
        }
        #expect(await trace.events.isEmpty)
    }

    @Test("Extracted plans compose into the surrounding sequence")
    func composesNestedPlans() async throws {
        let trace = ExecutionTrace()
        let nested = BootPlan {
            BootStep("nested-first") {
                await trace.append("nested-first")
            }
            BootStep("nested-second") {
                await trace.append("nested-second")
            }
        }
        let bootstrap = Bootstrap {
            BootStep("before") {
                await trace.append("before")
            }
            nested
            BootStep("after") {
                await trace.append("after")
            }
        }

        try await bootstrap.run()

        #expect(await trace.events == [
            "before",
            "nested-first",
            "nested-second",
            "after",
        ])
    }

    @Test("An extracted plan remains sequential inside a parallel group")
    func preservesExtractedPlanGroupingInsideParallel() async throws {
        let trace = ExecutionTrace()
        let nested = BootPlan {
            BootStep("nested-first") {
                await trace.append("nested-first")
            }
            BootStep("nested-second") {
                await trace.append("nested-second")
            }
        }
        let bootstrap = Bootstrap {
            Parallel {
                nested
                BootStep("sibling") {
                    await trace.append("sibling")
                }
            }
        }

        try await bootstrap.run()

        let events = await trace.events
        let firstIndex = try #require(events.firstIndex(of: "nested-first"))
        let secondIndex = try #require(events.firstIndex(of: "nested-second"))
        #expect(firstIndex < secondIndex)
    }

    @Test("A parallel failure cancels an unfinished sibling")
    func cancelsParallelSiblingAfterFailure() async {
        let trace = ExecutionTrace()
        let bootstrap = Bootstrap {
            Parallel {
                BootStep("failing") {
                    try await Task.sleep(for: .milliseconds(20))
                    throw TestFailure.expected
                }
                BootStep("unfinished") {
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch is CancellationError {
                        await trace.append("cancelled")
                        throw CancellationError()
                    }
                }
            }
        }

        await #expect(throws: TestFailure.self) {
            try await bootstrap.run()
        }
        #expect(await trace.events == ["cancelled"])
    }

    @Test("Conditionals and loops preserve declaration order")
    func supportsStandardBuilderControlFlow() async throws {
        let trace = ExecutionTrace()
        let includesConditionalStep = true
        let names = ["loop-one", "loop-two"]
        let bootstrap = Bootstrap {
            if includesConditionalStep {
                BootStep("conditional") {
                    await trace.append("conditional")
                }
            }

            for name in names {
                BootStep(name) {
                    await trace.append(name)
                }
            }
        }

        try await bootstrap.run()

        #expect(await trace.events == ["conditional", "loop-one", "loop-two"])
    }

    private func recordedPriority(
        for priority: TaskPriority?
    ) async throws -> TaskPriority {
        let probe = PriorityProbe()
        let step: BootStep
        if let priority {
            step = BootStep("priority", priority: priority) {
                await probe.record(Task.currentPriority)
            }
        } else {
            step = BootStep("priority") {
                await probe.record(Task.currentPriority)
            }
        }

        let bootstrap = Bootstrap {
            step
        }
        let runTask = Task.detached(priority: .background) {
            try await bootstrap.run()
        }

        let recordedPriority = await probe.next()
        try await runTask.value
        return recordedPriority
    }
}
