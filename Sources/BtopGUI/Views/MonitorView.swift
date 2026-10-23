import BtopCore
import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(spacing: 8) {
            HeaderView(monitor: monitor)
            HStack(spacing: 8) {
                CPUPanel(monitor: monitor)
                MemoryPanel(monitor: monitor)
                ResponsivenessPanel(monitor: monitor)
            }
            .frame(height: 150)
            CulpritView(monitor: monitor)
            if !monitor.autoPaused.isEmpty || !monitor.events.isEmpty {
                ThrottlePanel(monitor: monitor)
            }
            ProcessListView(monitor: monitor)
        }
        .padding(10)
        .frame(width: 940, height: 760)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var monitor: Monitor
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        HStack(spacing: 10) {
            let level = monitor.report.level
            HStack(spacing: 6) {
                Circle().fill(Theme.level(level)).frame(width: 9, height: 9)
                Text(level.label.uppercased()).font(Theme.mono(12, .bold)).foregroundStyle(Theme.level(level))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.level(level).opacity(0.15))
            .clipShape(Capsule())

            Text(monitor.report.reasons.isEmpty ? "plenty of headroom" : monitor.report.reasons.joined(separator: " · "))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)

            Spacer()

            Text("Auto-throttle").font(Theme.mono(11)).foregroundStyle(Theme.dim)
            Picker("", selection: $monitor.mode) {
                ForEach(ThrottleMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Off: never touch processes.\nDeprioritize: move CPU hogs to background priority when strained.\nDeprioritize + Pause: also pause the heaviest job when that isn't enough, and resume it once things calm down.")

            Menu {
                Button("Resume everything") { monitor.resumeEverything() }
                Toggle("Launch at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, on in LoginItem.set(on) }
                if !monitor.protectedNames.isEmpty {
                    Section("Never auto-throttled (click to remove)") {
                        ForEach(monitor.protectedNames, id: \.self) { name in
                            Button(name) { monitor.protectedNames.removeAll { $0 == name } }
                        }
                    }
                }
                Divider()
                Button("Quit btop-gui") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
        }
    }
}

// MARK: - System panels

struct CPUPanel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let cores = monitor.system?.perCore ?? []
        Panel(title: "cpu", trailing: String(format: "%.0f%%", (monitor.system?.cpuTotal ?? 0) * 100)) {
            Sparkline(values: monitor.cpuHistory).frame(height: 44)
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(Array(cores.enumerated()), id: \.offset) { i, usage in
                    HStack(spacing: 4) {
                        Text("C\(i)").font(Theme.mono(9)).foregroundStyle(Theme.dim).frame(width: 22, alignment: .leading)
                        MeterBar(fraction: usage, height: 5)
                        Text(String(format: "%3.0f", usage * 100)).font(Theme.mono(9)).frame(width: 22, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct MemoryPanel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let s = monitor.system
        let total = Double(s?.memTotal ?? 1)
        let used = Double(s?.memUsed ?? 0)
        Panel(title: "mem", trailing: "\(ByteFormat.short(s?.memUsed ?? 0)) / \(ByteFormat.short(s?.memTotal ?? 0))") {
            MeterBar(fraction: used / total, height: 9)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("pressure", s?.pressure.label ?? "—",
                    color: s?.pressure == .critical ? Theme.red : s?.pressure == .warning ? Theme.yellow : Theme.green)
                row("available", "\(s?.memAvailablePercent ?? 0)%",
                    color: Theme.meter(1 - Double(s?.memAvailablePercent ?? 100) / 100))
                row("app / wired", "\(ByteFormat.short(s?.memApp ?? 0)) / \(ByteFormat.short(s?.memWired ?? 0))")
                row("compressed", ByteFormat.short(s?.memCompressed ?? 0))
                row("swap", "\(ByteFormat.short(s?.swapUsed ?? 0)) / \(ByteFormat.short(s?.swapTotal ?? 0))",
                    color: (s?.swapUsed ?? 0) > (s?.memTotal ?? 0) / 2 ? Theme.yellow : Theme.text)
                row("swapping", "out \(ByteFormat.short(s?.swapOutRate ?? 0))/s · in \(ByteFormat.short(s?.swapInRate ?? 0))/s",
                    color: (s?.swapOutRate ?? 0) > 8_000_000 ? Theme.red : Theme.text)
            }
        }
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.text) -> some View {
        GridRow {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.dim)
            Text(value).font(Theme.mono(10, .semibold)).foregroundStyle(color)
        }
    }
}

struct ResponsivenessPanel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let s = monitor.system
        Panel(title: "responsiveness", trailing: String(format: "%.0f ms", monitor.latencyMs)) {
            Sparkline(values: monitor.latencyHistory, max: 200).frame(height: 44)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("sched delay").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Text(String(format: "%.0f ms", monitor.latencyMs)).font(Theme.mono(10, .semibold))
                        .foregroundStyle(monitor.latencyMs > 150 ? Theme.red : monitor.latencyMs > 40 ? Theme.yellow : Theme.green)
                }
                GridRow {
                    Text("load avg").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Text((s?.loadAverage ?? []).map { String(format: "%.2f", $0) }.joined(separator: " "))
                        .font(Theme.mono(10, .semibold))
                }
                GridRow {
                    Text("thermal").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    let thermal = s?.thermalState ?? 0
                    Text(["nominal", "fair", "serious", "critical"][min(thermal, 3)]).font(Theme.mono(10, .semibold))
                        .foregroundStyle(thermal >= 2 ? Theme.red : Theme.text)
                }
                GridRow {
                    Text("system cpu").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Text(percent(monitor.unattributedCPU))
                        .font(Theme.mono(10, .semibold))
                }
            }
            .help("Sched delay: how long a high-priority thread waits for a CPU — it spikes right before apps beachball.\nSystem CPU: CPU used by root-owned daemons and the kernel, which can't be read per process without root.")
        }
    }
}

// MARK: - Culprits

struct CulpritView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let candidates = monitor.groups.filter { $0.kind != .system }
        let topCPU = candidates.max { $0.cpu < $1.cpu }
        let topMem = candidates.max { $0.memory < $1.memory }
        HStack(spacing: 8) {
            card(title: "Top CPU", symbol: "flame.fill", group: topCPU,
                 metric: topCPU.map { percent($0.cpu) } ?? "—", highlighted: monitor.report.cpuDriven)
            card(title: "Top memory", symbol: "memorychip.fill", group: topMem,
                 metric: topMem.map { ByteFormat.short($0.memory) } ?? "—", highlighted: monitor.report.memoryDriven)
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private func card(title: String, symbol: String, group: ProcessGroup?, metric: String, highlighted: Bool) -> some View {
        let tint = highlighted && monitor.report.level >= .strained ? Theme.red : Theme.accent
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(Theme.mono(9, .bold)).foregroundStyle(Theme.dim)
                if let group {
                    HStack(spacing: 6) {
                        Text(group.name).font(Theme.mono(12, .bold)).lineLimit(1)
                        Text(metric).font(Theme.mono(12, .bold)).foregroundStyle(tint)
                        if group.members.count > 1 {
                            Text("\(group.members.count) procs").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        }
                    }
                } else {
                    Text("sampling…").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            if let group {
                GroupActions(monitor: monitor, group: group, labeled: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlighted && monitor.report.level >= .strained ? tint.opacity(0.7) : Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Pause/resume, quit/kill, and a menu of extras for a group (or a single process wrapped as one).
struct GroupActions: View {
    @ObservedObject var monitor: Monitor
    let group: ProcessGroup
    var labeled = false

    var body: some View {
        HStack(spacing: 4) {
            if group.kind == .system {
                Text("needs root").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            } else if labeled {
                if group.anyStopped {
                    LabeledButton(title: "Resume", symbol: "play.fill", tint: Theme.green) { monitor.resume(group) }
                } else {
                    LabeledButton(title: "Pause", symbol: "pause.fill", tint: Theme.yellow) { monitor.pause(group) }
                }
                LabeledButton(title: isApp ? "Quit" : "Kill", symbol: "xmark", tint: Theme.red) { monitor.kill(group, force: false) }
                extras
            } else {
                if group.anyStopped {
                    IconButton(symbol: "play.fill", help: "Resume", tint: Theme.green) { monitor.resume(group) }
                } else {
                    IconButton(symbol: "pause.fill", help: "Pause (SIGSTOP) — frees CPU now; memory is swapped out over time", tint: Theme.yellow) { monitor.pause(group) }
                }
                IconButton(symbol: "xmark", help: isApp ? "Quit app" : "Terminate (SIGTERM)", tint: Theme.red) { monitor.kill(group, force: false) }
                extras
            }
        }
    }

    private var isApp: Bool {
        if case .app = group.kind { return true }
        return false
    }

    private var extras: some View {
        Menu {
            Button(isApp ? "Force quit" : "Force kill (SIGKILL)") { monitor.kill(group, force: true) }
            if group.kind == .job {
                Button("Never auto-throttle “\(group.name)”") { monitor.protect(group) }
            }
            Divider()
            Button("Copy PID") { copy("\(group.root.pid)") }
            Button("Copy command") { copy(group.root.command) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Auto-throttle activity

struct ThrottlePanel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Panel(title: "auto-throttle", trailing: summary) {
            HStack(alignment: .top, spacing: 12) {
                if !monitor.autoPaused.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(monitor.autoPaused) { job in
                            HStack(spacing: 6) {
                                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.yellow)
                                Text(job.name).font(Theme.mono(11, .bold)).lineLimit(1)
                                Text("paused \(duration(since: job.pausedAt))").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                                Spacer()
                                LabeledButton(title: "Resume", symbol: "play.fill", tint: Theme.green) { monitor.resume(job) }
                            }
                            .help(job.reason)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(monitor.events.prefix(4)) { event in
                        Text("\(event.date.formatted(date: .omitted, time: .standard))  \(event.text)")
                            .font(Theme.mono(10))
                            .foregroundStyle(event.isAuto ? Theme.text : Theme.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: max(70, CGFloat(min(max(monitor.autoPaused.count, monitor.events.prefix(4).count), 4)) * 20 + 34))
    }

    private var summary: String {
        var parts: [String] = []
        if !monitor.autoPaused.isEmpty { parts.append("\(monitor.autoPaused.count) paused") }
        if !monitor.deprioritized.isEmpty { parts.append("\(monitor.deprioritized.count) deprioritized") }
        return parts.isEmpty ? monitor.mode.label.lowercased() : parts.joined(separator: " · ")
    }
}
