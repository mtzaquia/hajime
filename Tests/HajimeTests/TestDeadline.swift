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

/// Bounds probe polling without changing the cancellation behavior under test.
struct TestDeadline {
    private let instant: ContinuousClock.Instant
    private let condition: String
    private let sourceLocation: SourceLocation

    init(
        _ condition: String,
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        instant = .now.advanced(by: timeout)
        self.condition = condition
        self.sourceLocation = sourceLocation
    }

    func check() throws {
        guard ContinuousClock.now < instant else {
            throw ProbeTimeout(condition: condition, sourceLocation: sourceLocation)
        }
    }
}

private struct ProbeTimeout: Error, CustomStringConvertible {
    let condition: String
    let sourceLocation: SourceLocation

    var description: String {
        "Timed out waiting for probe condition to clear: \(condition) (\(sourceLocation))"
    }
}
