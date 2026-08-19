import Hajime
import Observation
import SwiftUI

public struct ContentView: View {
    @State private var lab = BootLab()

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HeroCard(lab: lab)
                    planCard
                    traceCard
                    performanceCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color.secondary.opacity(0.05))
        }
        .tint(.orange)
    }

    private var planCard: some View {
        DemoCard {
            CardHeading(
                number: "01",
                title: "Start and await readiness",
                detail: "The cache gets a 0.3-second readiness budget, then the same step continues without delaying the app."
            )

            VStack(spacing: 10) {
                StepRow(step: lab.step(.foundation))

                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)

                ParallelGroup {
                    StepRow(step: lab.step(.session))
                    StepRow(step: lab.step(.flags))
                }

                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)

                NonBlockingStepGroup {
                    StepRow(step: lab.step(.cache))
                }

                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)

                StepRow(step: lab.step(.routing))
            }

            Button {
                lab.run()
            } label: {
                HStack {
                    Image(systemName: lab.isRunning ? "hourglass" : "play.fill")
                    Text(lab.isRunning ? "Booting…" : lab.hasRun ? "Restart boot" : "Start boot")
                    Spacer()
                    if lab.isRunning {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(lab.isRunning)

            Button("Reset", systemImage: "arrow.counterclockwise") {
                lab.reset()
            }
            .buttonStyle(.bordered)
            .disabled(!lab.hasRun && !lab.isRunning)
        }
    }

    private var traceCard: some View {
        DemoCard {
            CardHeading(
                number: "02",
                title: "Inspect execution",
                detail: "Readiness appears before the cache step completes, making its one-way transition visible without relying on console output."
            )

            if lab.events.isEmpty {
                ContentUnavailableView(
                    "No execution yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Run the plan to populate its deterministic trace.")
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(lab.events) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(event.elapsed)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)

                            Circle()
                                .fill(event.kind.tint)
                                .frame(width: 8, height: 8)

                            Text(event.message)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 9)

                        if event.id != lab.events.last?.id {
                            Divider().padding(.leading, 82)
                        }
                    }
                }
            }
        }
    }

    private var performanceCard: some View {
        DemoCard {
            CardHeading(
                number: "03",
                title: "Inspect performance",
                detail: "These intervals come from BootInstrumentation, the same release-safe stream available to Instruments and telemetry."
            )

            if lab.measurements.isEmpty {
                ContentUnavailableView(
                    "No measurements yet",
                    systemImage: "gauge.with.dots.needle.50percent",
                    description: Text("Run the plan to measure its orchestration boundaries.")
                )
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(lab.measurements.enumerated()),
                        id: \.offset
                    ) { index, measurement in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(measurement.formattedDuration)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(measurement.scopeTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text(measurement.scopeDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: measurement.outcomeSymbol)
                                .foregroundStyle(measurement.outcomeTint)
                        }
                        .padding(.vertical, 9)

                        if index != lab.measurements.count - 1 {
                            Divider().padding(.leading, 74)
                        }
                    }
                }
            }
        }
    }
}

@Observable
@MainActor
private final class BootLab {
    enum StepID: String, CaseIterable, Sendable {
        case foundation = "configure-foundation"
        case session = "restore-session"
        case flags = "load-feature-flags"
        case cache = "warm-disk-cache"
        case routing = "prepare-routing"
    }

    private(set) var steps: [StepID: LabStep] = [
        .foundation: LabStep(
            id: .foundation,
            title: "Configure foundation",
            detail: "Sequential · 0.6 seconds"
        ),
        .session: LabStep(
            id: .session,
            title: "Restore session",
            detail: "Parallel · 1.2 seconds"
        ),
        .flags: LabStep(
            id: .flags,
            title: "Load feature flags",
            detail: "Parallel · 0.8 seconds"
        ),
        .cache: LabStep(
            id: .cache,
            title: "Warm disk cache",
            detail: "Demotes after 0.3s · utility · 2.0s total"
        ),
        .routing: LabStep(
            id: .routing,
            title: "Prepare routing",
            detail: "Sequential · 0.5 seconds"
        ),
    ]
    private(set) var events: [LabEvent] = []
    private(set) var measurements: [BootInstrumentation.Measurement] = []
    private(set) var hasRun = false

    private var startedAt: ContinuousClock.Instant?
    private var runTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var bootstrap: Bootstrap?
    private var runAttempt: UInt64 = 0

    init() {
        Hajime.debug = .trace
        bootstrap = makeBootstrap()
    }

    var isRunning: Bool {
        bootstrap?.state == .booting
    }

    func step(_ id: StepID) -> LabStep {
        steps[id]!
    }

    func run() {
        reset()
        runAttempt &+= 1
        hasRun = true
        startedAt = .now
        append("Boot started", kind: .plan)

        guard let bootstrap else { return }
        let progress = bootstrap.progress
        progressTask = Task { [weak self] in
            for await step in progress {
                guard let self else { return }
                record(step)
            }
        }
        bootstrap.start()

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await bootstrap.waitUntilReady()
                append("App ready · isReady=\(bootstrap.isReady)", kind: .plan)
            } catch is CancellationError {
                return
            } catch {
                append("Plan failed: \(type(of: error))", kind: .failure)
            }

            runTask = nil
        }
    }

    func reset() {
        bootstrap?.cancel()
        runTask?.cancel()
        progressTask?.cancel()
        runTask = nil
        progressTask = nil
        hasRun = false
        events = []
        measurements = []
        startedAt = nil

        for id in StepID.allCases {
            steps[id]?.state = .pending
        }
    }

    private func makeBootstrap() -> Bootstrap {
        Bootstrap(
            "app-launch",
            instrumentation: .measurements { [weak self] measurement in
                Task { @MainActor [weak self] in
                    self?.record(measurement)
                }
            }
        ) {
            BootStep("configure-foundation") {
                try await Task.sleep(for: .milliseconds(600))
            }

            Parallel {
                BootStep("restore-session") {
                    try await Task.sleep(for: .milliseconds(1_200))
                }
                BootStep("load-feature-flags") {
                    try await Task.sleep(for: .milliseconds(800))
                }
            }

            BootStep(
                "warm-disk-cache",
                priority: .utility
            ) {
                try await Task.sleep(for: .seconds(2))
            }
            .nonBlocking(after: .milliseconds(300))

            BootStep("prepare-routing") {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func record(_ progress: BootProgress) {
        guard hasRun,
              progress.attempt == runAttempt,
              let id = StepID(rawValue: progress.name)
        else { return }

        let state: LabStep.State
        let message: String
        let kind: LabEvent.Kind
        switch progress.phase {
        case .running:
            state = .running
            message = "\(step(id).title) started"
            kind = .started
        case .continuing:
            state = .continuing
            message = "\(step(id).title) released readiness"
            kind = .plan
        case .succeeded:
            state = .completed
            message = "\(step(id).title) completed"
            kind = .completed
        case .failed(let failure):
            state = .failed
            message = "\(step(id).title) failed: \(failure.errorType)"
            kind = .failure
        case .cancelled:
            state = .cancelled
            message = "\(step(id).title) cancelled"
            kind = .plan
        }

        steps[id]?.state = state
        append(message, kind: kind)
    }

    private func record(_ measurement: BootInstrumentation.Measurement) {
        guard hasRun, measurement.attempt == runAttempt else { return }
        measurements.append(measurement)
        measurements.sort { $0.startOffset < $1.startOffset }
    }

    private func append(_ message: String, kind: LabEvent.Kind) {
        let elapsed: Duration
        if let startedAt {
            elapsed = startedAt.duration(to: .now)
        } else {
            elapsed = .zero
        }

        events.append(LabEvent(message: message, kind: kind, duration: elapsed))
    }
}

private extension BootInstrumentation.Measurement {
    var scopeTitle: String {
        switch scope {
        case .bootstrap: "Complete boot"
        case .scheduling: "Scheduling"
        case .step(let name, _): name
        case .operation(let step): "\(step) operation"
        case .signalWait(let signal, _): "Wait for \(signal)"
        case .signalHandler(let signals, _): "Handle \(signals.joined(separator: ", "))"
        case .parallel: "Parallel group"
        case .nonBlocking(let step): "\(step) after readiness"
        case .readinessBudget(let step): "\(step) readiness budget"
        }
    }

    var scopeDetail: String {
        switch scope {
        case .bootstrap:
            "attempt \(attempt) · request to readiness"
        case .scheduling:
            "request to execution"
        case .step(_, let priority):
            "complete step · priority \(priority.sampleDescription)"
        case .operation:
            "step closure only"
        case .signalWait(_, let step), .signalHandler(_, let step):
            "step \(step)"
        case .parallel:
            "all children"
        case .nonBlocking:
            "continued after releasing readiness"
        case .readinessBudget:
            "blocking until completion or configured budget"
        }
    }

    var formattedDuration: String {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return String(format: "%.0f ms", Double(milliseconds))
    }

    var outcomeSymbol: String {
        switch outcome {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle.fill"
        case .releasedReadiness: "arrow.up.right.circle.fill"
        }
    }

    var outcomeTint: Color {
        switch outcome {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        case .releasedReadiness: .teal
        }
    }
}

private extension TaskPriority {
    var sampleDescription: String {
        if self == .userInitiated { return "user initiated" }
        if self == .medium { return "medium" }
        if self == .utility { return "utility" }
        if self == .background { return "background" }
        return "custom"
    }
}

private struct LabStep: Identifiable {
    enum State: Equatable {
        case pending
        case running
        case continuing
        case completed
        case failed
        case cancelled

        var title: String {
            switch self {
            case .pending: "Pending"
            case .running: "Running"
            case .continuing: "Continuing"
            case .completed: "Complete"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        var symbol: String {
            switch self {
            case .pending: "circle.dashed"
            case .running: "arrow.trianglehead.2.clockwise.rotate.90"
            case .continuing: "arrow.turn.up.right"
            case .completed: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .cancelled: "slash.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .pending: .secondary
            case .running: .orange
            case .continuing: .teal
            case .completed: .green
            case .failed: .red
            case .cancelled: .secondary
            }
        }
    }

    let id: BootLab.StepID
    let title: String
    let detail: String
    var state: State = .pending
}

private struct LabEvent: Identifiable {
    enum Kind {
        case plan
        case started
        case completed
        case failure

        var tint: Color {
            switch self {
            case .plan: .indigo
            case .started: .orange
            case .completed: .green
            case .failure: .red
            }
        }
    }

    let id = UUID()
    let message: String
    let kind: Kind
    let duration: Duration

    var elapsed: String {
        let components = duration.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return String(format: "+%.2fs", Double(milliseconds) / 1_000)
    }
}

private struct HeroCard: View {
    let lab: BootLab

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("INTERACTIVE SAMPLE", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                Spacer()
                Text(status)
                    .font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.16), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Hajime Boot Lab")
                    .font(.largeTitle.bold())
                Text("Watch declaration order form a predictable boot timeline—and see independent work overlap.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 10) {
                Label("Sequence", systemImage: "arrow.down")
                Spacer()
                Label("Parallel", systemImage: "arrow.left.and.right")
                Spacer()
                Label("Non-blocking", systemImage: "arrow.turn.up.right")
            }
            .font(.caption.weight(.semibold))
            .padding(12)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [.orange, .pink, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .shadow(color: .orange.opacity(0.18), radius: 20, y: 10)
        .padding(.top, 8)
    }

    private var status: String {
        if lab.isRunning { return "BOOTING" }
        if lab.hasRun { return "READY" }
        return "IDLE"
    }
}

private struct ParallelGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Parallel", systemImage: "arrow.left.and.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.indigo)
            content()
        }
        .padding(12)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.indigo.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
    }
}

private struct NonBlockingStepGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Non-blocking after 0.3s", systemImage: "arrow.turn.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.teal)
            content()
        }
        .padding(12)
        .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    .teal.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                )
        }
    }
}

private struct StepRow: View {
    let step: LabStep

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.state.symbol)
                .font(.title3)
                .foregroundStyle(step.state.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(step.state.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(step.state.tint)
        }
        .padding(13)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct CardHeading: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold().monospaced())
                .foregroundStyle(.orange)
                .padding(8)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DemoCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(
                configuration.isPressed ? Color.orange.opacity(0.72) : Color.orange,
                in: RoundedRectangle(cornerRadius: 15)
            )
    }
}
