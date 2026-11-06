import AppKit
import CaseCore
import SwiftUI

/// Notices when the main thread stops responding: a background timer
/// sends the main thread a tiny task every 0.2 s and measures how long it
/// takes to run. Longer than `threshold` is reported (on the main thread,
/// once it is free again).
final class StallMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.qdvc.case-manager.stall-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Accessed only on `queue`.
    private var waiting = false
    private let threshold: TimeInterval
    private let report: @Sendable (TimeInterval) -> Void

    init(threshold: TimeInterval, report: @escaping @Sendable (TimeInterval) -> Void) {
        self.threshold = threshold
        self.report = report
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 0.2, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !waiting else { return }
        waiting = true
        let sent = DispatchTime.now().uptimeNanoseconds
        let threshold = self.threshold
        let report = self.report
        DispatchQueue.main.async { [weak self] in
            let lag = TimeInterval(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000_000
            if lag >= threshold { report(lag) }
            self?.queue.async { self?.waiting = false }
        }
    }
}

/// The strip along the bottom of the main window: what the app is busy
/// with, what the table shows, and any moments it stopped responding.
struct StatusBar: View {
    var model: AppModel
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 10) {
            if !model.activities.isEmpty {
                ProgressView().controlSize(.mini)
                Text(model.activities.map(\.title).joined(separator: " · ") + "…")
                    .lineLimit(1)
            } else if model.isUpdating {
                ProgressView().controlSize(.mini)
                Text("Updating figures…")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(idleText).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if case .cases = model.page {
                Text(shownText).foregroundStyle(.secondary).lineLimit(1)
            }
            if let last = model.stalls.first {
                Button {
                    showLog = true
                } label: {
                    Label("Stopped responding for \(AppModel.duration(last.duration))", systemImage: "tortoise.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("The app stopped responding \(model.stalls.count) time\(model.stalls.count == 1 ? "" : "s"). Click for details.")
            }
            Button {
                showLog.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Activity: what the app has been doing, and for how long")
            .popover(isPresented: $showLog, arrowEdge: .top) {
                ActivityLogView(model: model)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var idleText: String {
        guard let last = model.activityLog.first(where: { $0.title == "Updating figures" }) else { return "Ready" }
        let time = last.finished.formatted(date: .omitted, time: .shortened)
        return "Up to date · figures updated at \(time) in \(AppModel.duration(last.duration))"
    }

    private var shownText: String {
        let year = model.selectedYear == YearSummary.undated ? "no date" : String(model.selectedYear)
        return "\(model.caseRows.count) case\(model.caseRows.count == 1 ? "" : "s") shown · \(year)"
    }
}

/// The status bar's popover: freezes, then recent work with timings.
struct ActivityLogView: View {
    var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline)
            Text("Work on the main thread holds up the window while it runs; background work doesn't.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.stalls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stopped responding").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            ForEach(model.stalls) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(s.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(AppModel.duration(s.duration)).monospacedDigit().foregroundStyle(.orange)
                                        .frame(width: 56, alignment: .trailing)
                                    Text(s.context).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent work").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if model.activityLog.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(model.activityLog) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r.finished.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(AppModel.duration(r.duration)).monospacedDigit()
                                    .foregroundStyle(r.onMainThread && r.duration > 0.25 ? Color.orange : Color.primary)
                                    .frame(width: 56, alignment: .trailing)
                                Text(r.title)
                                if !r.onMainThread {
                                    Text("background").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                Button(copied ? "Copied" : "Copy Report") {
                    Platform.copy(model.activityReport)
                    copied = true
                }
                .help("Copy this log as text, to send with a description of what you were doing")
                Spacer()
                Button("Clear") { model.clearActivityLog() }
            }
        }
        .padding(14)
        .frame(width: 520)
    }
}
