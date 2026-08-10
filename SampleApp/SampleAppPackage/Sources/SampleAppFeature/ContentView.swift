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
                title: "Run the boot plan",
                detail: "Root steps wait for each other. The two service steps overlap inside Parallel."
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

                StepRow(step: lab.step(.routing))
            }

            Button {
                lab.run()
            } label: {
                HStack {
                    Image(systemName: lab.isRunning ? "hourglass" : "play.fill")
                    Text(lab.isRunning ? "Running plan…" : lab.hasRun ? "Replay plan" : "Run plan")
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
                detail: "Start and finish events make ordering and overlap visible without relying on console output."
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
}

@Observable
@MainActor
private final class BootLab {
    enum StepID: String, CaseIterable, Sendable {
        case foundation
        case session
        case flags
        case routing
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
        .routing: LabStep(
            id: .routing,
            title: "Prepare routing",
            detail: "Sequential · 0.5 seconds"
        ),
    ]
    private(set) var events: [LabEvent] = []
    private(set) var isRunning = false
    private(set) var hasRun = false

    private var startedAt: ContinuousClock.Instant?
    private var runTask: Task<Void, Never>?

    func step(_ id: StepID) -> LabStep {
        steps[id]!
    }

    func run() {
        reset()
        isRunning = true
        hasRun = true
        startedAt = .now
        append("Plan started", kind: .plan)

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await makeBootstrap().run()
                append("Plan completed", kind: .plan)
            } catch is CancellationError {
                return
            } catch {
                append("Plan failed: \(type(of: error))", kind: .failure)
            }

            isRunning = false
            runTask = nil
        }
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        hasRun = false
        events = []
        startedAt = nil

        for id in StepID.allCases {
            steps[id]?.state = .pending
        }
    }

    private func makeBootstrap() -> Bootstrap {
        Bootstrap {
            BootStep("configure-foundation") { @MainActor [weak self] in
                try await self?.perform(.foundation, for: .milliseconds(600))
            }

            Parallel {
                BootStep("restore-session") { @MainActor [weak self] in
                    try await self?.perform(.session, for: .milliseconds(1_200))
                }
                BootStep("load-feature-flags") { @MainActor [weak self] in
                    try await self?.perform(.flags, for: .milliseconds(800))
                }
            }

            BootStep("prepare-routing") { @MainActor [weak self] in
                try await self?.perform(.routing, for: .milliseconds(500))
            }
        }
    }

    private func perform(_ id: StepID, for duration: Duration) async throws {
        steps[id]?.state = .running
        append("\(step(id).title) started", kind: .started)

        do {
            try await Task.sleep(for: duration)
            steps[id]?.state = .completed
            append("\(step(id).title) completed", kind: .completed)
        } catch {
            steps[id]?.state = .pending
            throw error
        }
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

private struct LabStep: Identifiable {
    enum State {
        case pending
        case running
        case completed

        var title: String {
            switch self {
            case .pending: "Pending"
            case .running: "Running"
            case .completed: "Complete"
            }
        }

        var symbol: String {
            switch self {
            case .pending: "circle.dashed"
            case .running: "arrow.trianglehead.2.clockwise.rotate.90"
            case .completed: "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .pending: .secondary
            case .running: .orange
            case .completed: .green
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
            }
            .font(.subheadline.weight(.semibold))
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
        if lab.isRunning { return "RUNNING" }
        if lab.hasRun { return "COMPLETE" }
        return "READY"
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
