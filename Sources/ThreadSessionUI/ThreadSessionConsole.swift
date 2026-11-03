#if canImport(SwiftUI)
import SwiftUI
import ThreadSession

/// A console for watching one thread session survive the iOS lifecycle: the phase, every
/// request's path, upload size and TTFT, and the keep-warm economics.
public struct ThreadSessionConsole: View {
    @StateObject private var model: ThreadSessionConsoleModel
    @Environment(\.scenePhase) private var scenePhase
    private let autorun: Bool

    public init(configuration: ConsoleConfiguration, autorun: Bool = false) {
        _model = StateObject(wrappedValue: ThreadSessionConsoleModel(configuration: configuration))
        self.autorun = autorun
    }

    public var body: some View {
        NavigationStack {
            List {
                statusSection
                if let banner = model.banner {
                    Section("Last action") { Text(banner).font(.callout.monospaced()).accessibilityIdentifier("banner") }
                }
                telemetrySection
                controlsSection
                transcriptSection
                composerSection
            }
            .navigationTitle(model.configuration.title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
        }
        .task {
            await model.refresh()
            await model.startLiveObservers()
            if autorun { await model.runScript() }
        }
        .task(id: model.isLive) {
            // Live mode: refresh the countdown every second and let the policy consider a ping
            // every 15 s. iOS suspends this loop with the app; nothing depends on it firing.
            guard model.isLive else { return }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick &+= 1
                if tick % 15 == 0 { await model.liveTick() } else { await model.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // `.inactive` (Control Center, the app switcher) is not backgrounding: ignore it.
            switch phase {
            case .active: Task { await model.scenePhaseChanged(isActive: true) }
            case .background: Task { await model.scenePhaseChanged(isActive: false) }
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            Task { await model.lowPowerModeChanged() }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Thread") {
            HStack {
                PhaseBadge(phase: model.snapshot?.phase ?? .fresh)
                Text(verbatim: model.isLive ? "live clock" : "simulated clock").font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: model.snapshot?.anchor?.threadID ?? "no thread").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(remainingText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let s = model.snapshot {
                Text(verbatim: "\(s.contextTokens) tokens in context · \(s.stats.reuploadedTokens) re-uploaded")
                    .font(.caption.monospacedDigit())
                Text(verbatim: "\(s.stats.requests) requests: \(s.stats.deltas) delta · \(s.stats.fullResends) full · \(s.stats.rejectedDeltas) rejected · \(s.stats.keepWarms) keep-warm")
                    .font(.caption.monospacedDigit())
                Text(verbatim: "Keep-warm \(ThreadSessionConsoleModel.describe(s.keepWarm)) · break-even \(breakEvenText)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "Reminders created: \(model.remindersCreated)").font(.caption)
            }
        }
    }

    private var controlsSection: some View {
        Section(model.isLive ? "Lifecycle (real scene phase, Low Power Mode, network path)" : "Lifecycle (simulated)") {
            ControlGrid {
                if !model.isLive {
                    // Simulated mode: time travel and synthetic lifecycle events.
                    StepButton("Wait 2 min", "clock") { await model.perform(.wait(120)) }
                    StepButton("Sleep 20 min", "moon.zzz") { await model.perform(.sleepContinuousClock(1200)) }
                    StepButton("Sleep 20 min · paused clock", "exclamationmark.triangle") { await model.perform(.sleepPausingClock(1200)) }
                    StepButton(isBackground ? "Foreground" : "Background", "rectangle.on.rectangle") {
                        await model.perform(isBackground ? .enterForeground : .enterBackground)
                    }
                    StepButton((model.snapshot?.conditions.isLowPowerMode ?? false) ? "Low Power off" : "Low Power on", "battery.25") {
                        await model.toggleLowPower()
                    }
                }
                StepButton("Keep-warm tick", "flame") { await model.perform(.keepWarmTick) }
                StepButton("Server evicts", "trash") { await model.perform(.evictServerThread) }
                StepButton("Redact msg #1", "eye.slash") { await model.perform(.redactFirstMessage) }
                StepButton("Drop after tool", "wifi.exclamationmark") { await model.perform(.armNetworkHandoff) }
                StepButton("Reset", "arrow.counterclockwise") { await model.reset() }
            }
            .disabled(model.busy)
        }
    }

    private var telemetrySection: some View {
        Section("Requests (newest first)") {
            let records = Array((model.snapshot?.records ?? []).reversed())
            if records.isEmpty {
                Text("No requests yet. Send a message.").foregroundStyle(.secondary)
            } else {
                ForEach(records) { r in
                    HStack {
                        Text(r.path.label).font(.caption.monospaced()).foregroundStyle(color(for: r.path))
                        Spacer()
                        Text(verbatim: "↑\(r.uploadedTokens)").font(.caption.monospacedDigit())
                        Text(r.ttftMs.flatMap(Self.milliseconds) ?? "—")
                            .font(.caption.monospacedDigit()).frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var transcriptSection: some View {
        Section("Transcript (\(model.snapshot?.messages.count ?? 0))") {
            let messages = model.snapshot?.messages ?? []
            if messages.isEmpty {
                Text("Empty").foregroundStyle(.secondary)
            } else {
                // Only the newest few: the seed context is ~400 KB of text.
                ForEach(Array(messages.enumerated().suffix(6)), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "#\(item.offset) \(item.element.role.rawValue)").font(.caption2).foregroundStyle(.secondary)
                        Text(String(item.element.plainText.prefix(160))).font(.callout).lineLimit(3)
                    }
                }
            }
        }
    }

    private var composerSection: some View {
        Section("Send") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(model.configuration.suggestedPrompts, id: \.self) { p in
                        Button(p) { Task { await model.send(p) } }.buttonStyle(.bordered).font(.caption)
                            .disabled(model.busy)
                    }
                }
            }
            HStack {
                TextField("Message", text: $model.draft)
                Button("Send") {
                    let text = model.draft
                    model.draft = ""
                    Task { await model.send(text) }
                }
                .disabled(model.busy)
            }
            if model.lastFailedText != nil {
                Button("Retry last turn") { Task { await model.retryLastTurn() } }.disabled(model.busy)
            }
        }
    }

    // MARK: Helpers

    /// Formats a TTFT without trapping: a transport could report NaN or infinity.
    static func milliseconds(_ ms: Double) -> String? {
        guard ms.isFinite, ms >= 0, ms < 1e12 else { return nil }
        return "\(Int(ms.rounded())) ms"
    }

    private var isBackground: Bool { !(model.snapshot?.conditions.isForeground ?? true) }

    private var remainingText: String {
        switch model.snapshot?.liveness {
        case let .live(r)?, let .expiring(r)?: return r.isFinite ? "\(Int(max(0, min(r, 1e9)))) s left" : "—"
        case .expired?: return "TTL elapsed"
        case nil: return "no thread"
        }
    }

    private var breakEvenText: String {
        let v = model.configuration.keepWarm.breakEvenDollarsPerSecond
        let mine = model.configuration.keepWarm.dollarsPerSecondSaved
        guard v.isFinite else { return "pings disabled" }
        return String(format: "$%.3f/s (this app: $%.3f/s)", v, mine)
    }

    private func color(for path: TurnPath) -> Color {
        switch path {
        case .delta: return .green
        case .started, .keepWarm: return .blue
        case .rehydrated: return .orange
        case .rejectedDelta, .failed: return .red
        }
    }
}

private struct PhaseBadge: View {
    let phase: SessionPhase
    var body: some View {
        Text(phase.rawValue.uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityIdentifier("phase")
    }
    private var tint: Color {
        switch phase {
        case .fresh: return .gray
        case .starting: return .blue
        case .threaded: return .green
        case .expiring: return .yellow
        case .expired: return .red
        case .rehydrating: return .orange
        }
    }
}

private struct ControlGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) { content }
            .buttonStyle(.bordered)
    }
}

private struct StepButton: View {
    let title: String
    let icon: String
    let action: @MainActor () async -> Void
    init(_ title: String, _ icon: String, action: @escaping @MainActor () async -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }
    var body: some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
#endif
