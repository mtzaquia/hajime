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

/// The latest execution phase emitted for one boot-step occurrence.
///
/// A bootstrap emits the same step ID as its phase changes. Consumers can keep
/// only the latest value for each ID to render current progress, or retain every
/// value to build an execution timeline. IDs remain stable across attempts of
/// one ``Bootstrap`` even when multiple declarations use the same name.
public struct BootProgress: Identifiable, Sendable {
    /// An opaque identity for one step occurrence in a bootstrap plan.
    public struct ID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        init() {
            rawValue = UUID()
        }
    }

    /// The execution phase of a boot step.
    public enum Phase: Sendable {
        /// The step is active and still contributes to application readiness.
        case running

        /// The step remains active after releasing application readiness.
        case continuing

        /// The complete step, including its signal requirements, succeeded.
        case succeeded

        /// The step ended with its retained failure.
        case failed(Bootstrap.Failure)

        /// Cancellation was requested and the step is no longer active for this
        /// bootstrap attempt.
        case cancelled
    }

    /// The stable identity of the step occurrence.
    public let id: ID

    /// The one-based execution number of the bootstrap coordinator.
    public let attempt: UInt64

    /// The developer-authored diagnostic name of the step.
    public let name: String

    /// The latest phase reached by the step.
    public let phase: Phase

    init(
        id: ID,
        attempt: UInt64,
        name: String,
        phase: Phase
    ) {
        self.id = id
        self.attempt = attempt
        self.name = name
        self.phase = phase
    }

    func changingPhase(to phase: Phase) -> BootProgress {
        BootProgress(
            id: id,
            attempt: attempt,
            name: name,
            phase: phase
        )
    }
}

extension BootProgress.Phase {
    var isActive: Bool {
        switch self {
        case .running, .continuing:
            true
        case .succeeded, .failed, .cancelled:
            false
        }
    }
}
