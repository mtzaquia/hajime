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

/// Executes an immutable application boot plan.
///
/// Each call to ``run()`` starts a new execution. Declarations at the root of
/// the plan run sequentially, while declarations inside ``Parallel`` begin
/// concurrently.
public struct Bootstrap: Sendable {
    private let plan: BootPlan

    /// Creates a bootstrap runner from inline boot declarations.
    ///
    /// - Parameter content: The declarations that make up the boot plan.
    public init(@BootPlanBuilder _ content: () -> BootPlan) {
        plan = content()
    }

    /// Creates a bootstrap runner from a reusable plan.
    ///
    /// - Parameter plan: The immutable plan to execute.
    public init(plan: BootPlan) {
        self.plan = plan
    }

    /// Executes the plan and returns after every declaration succeeds.
    ///
    /// The first propagated error prevents subsequent sequential declarations
    /// from starting. A failure in ``Parallel`` requests cancellation of
    /// unfinished siblings before the error leaves the group.
    ///
    /// - Throws: An error thrown by a boot step, including cancellation.
    public func run() async throws {
        try await plan.execute()
    }
}
