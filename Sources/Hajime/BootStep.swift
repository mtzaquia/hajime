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
/// each other run sequentially unless they are nested in ``Parallel``.
public struct BootStep: Sendable {
    /// The caller-provided name used to describe this operation.
    public let name: String

    let operation: @isolated(any) @Sendable () async throws -> Void

    /// Creates a named boot step from an asynchronous operation.
    ///
    /// The operation may inherit actor isolation from its declaration. Throwing
    /// an error stops the surrounding sequential plan. Inside ``Parallel``, the
    /// error also requests cancellation of unfinished sibling operations.
    ///
    /// - Parameters:
    ///   - name: A stable, caller-readable name for the operation.
    ///   - operation: The work to perform when execution reaches the step.
    public init(
        _ name: String,
        operation: @isolated(any) @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.operation = operation
    }
}
