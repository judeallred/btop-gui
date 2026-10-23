import Foundation

public enum ThrottleMode: String, CaseIterable, Codable, Sendable {
    case off
    /// Tier 1 only: move CPU hogs to background priority.
    case deprioritize
    /// Tier 1, plus pause (SIGSTOP) the heaviest job when deprioritizing isn't enough.
    case full

    public var label: String {
        switch self {
        case .off: "Off"
        case .deprioritize: "Deprioritize"
        case .full: "Deprioritize + Pause"
        }
    }
}

public struct ThrottleConfig: Sendable {
    public var mode: ThrottleMode = .full
    /// Per-process CPU (% of one core) above which a process gets background priority when strained.
    public var deprioritizeMinCPU = 30.0
    /// A job must use at least this much CPU to be paused for CPU reasons.
    public var pauseMinCPU = 100.0
    /// A job must use at least this much memory to be paused for memory reasons.
    public var pauseMinMemory: UInt64 = 1 << 30
    /// How long CPU strain must persist (after deprioritizing) before pausing.
    public var cpuStrainSecondsBeforePause: TimeInterval = 20
    /// Deprioritizing doesn't relieve memory, so memory strain escalates to pausing sooner.
    public var memoryStrainSecondsBeforePause: TimeInterval = 8
    public var pauseCooldown: TimeInterval = 6
    /// Calm time required before resuming a paused job. Doubles each time the same job gets re-paused.
    public var resumeCalmSeconds: TimeInterval = 20
    public var maxResumeCalmSeconds: TimeInterval = 600
    public var resumeSpacing: TimeInterval = 15
    public var restorePriorityCalmSeconds: TimeInterval = 30
    /// After you manually resume something, auto-throttle leaves it alone this long.
    public var manualOverrideGrace: TimeInterval = 300

    public init(mode: ThrottleMode = .full) { self.mode = mode }
}

public struct ThrottledJob: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let members: [ProcessKey]
    public let pausedAt: Date
    public let reason: String
    public let cpu: Double
    public let memory: UInt64
}

public enum ThrottleAction: Sendable, Equatable {
    case deprioritize(ProcessKey, name: String)
    case restorePriority(ProcessKey, name: String)
    case pause(ThrottledJob)
    case resume(ThrottledJob)
}

/// Decides what to throttle. Pure bookkeeping: it returns actions and the caller performs them.
///
/// Escalation, gentlest first:
///  1. Strained by CPU → hogs move to background priority (E-cores, low I/O priority). Nothing stops.
///  2. Still strained after a while, or lagging, or memory-bound → pause the heaviest job tree.
///  3. Once calm → resume paused jobs one at a time (oldest first), then restore priorities.
public final class ThrottleEngine {
    public var config: ThrottleConfig
    public private(set) var paused: [ThrottledJob] = []
    public private(set) var deprioritized: [ProcessKey: String] = [:]

    private var strainedSince: Date?
    private var calmSince: Date?
    private var okSince: Date?
    private var lastPause = Date.distantPast
    private var lastResume = Date.distantPast
    private var pauseCounts: [String: Int] = [:]
    private var overrides: [String: Date] = [:]

    public init(config: ThrottleConfig = ThrottleConfig()) {
        self.config = config
    }

    public var isThrottling: Bool { !paused.isEmpty || !deprioritized.isEmpty }

    public var ledger: ThrottleLedger {
        ThrottleLedger(paused: paused.flatMap(\.members), deprioritized: Array(deprioritized.keys))
    }

    public func step(report: HealthReport, groups: [ProcessGroup], rules: ProtectionRules, now: Date = Date()) -> [ThrottleAction] {
        prune(groups: groups, now: now)

        if report.level >= .strained {
            strainedSince = strainedSince ?? now
            calmSince = nil
        } else {
            strainedSince = nil
            calmSince = calmSince ?? now
        }
        okSince = report.level == .ok ? (okSince ?? now) : nil

        switch config.mode {
        case .off:
            return releaseAll()
        case .deprioritize:
            var actions = paused.map { ThrottleAction.resume($0) }
            paused.removeAll()
            actions += tierOne(report: report, groups: groups, rules: rules, now: now)
            return actions
        case .full:
            if let pause = tierTwo(report: report, groups: groups, rules: rules, now: now) {
                return [pause]
            }
            if let resume = nextResume(now: now) {
                return [resume]
            }
            return tierOne(report: report, groups: groups, rules: rules, now: now)
        }
    }

    /// Call when the user resumes a job by hand; auto-throttle then leaves it alone for a while.
    public func userResumed(groupID: String, now: Date = Date()) {
        paused.removeAll { $0.id == groupID }
        overrides[groupID] = now.addingTimeInterval(config.manualOverrideGrace)
    }

    public func releaseAll() -> [ThrottleAction] {
        let actions = paused.map { ThrottleAction.resume($0) }
            + deprioritized.map { ThrottleAction.restorePriority($0.key, name: $0.value) }
        paused.removeAll()
        deprioritized.removeAll()
        return actions
    }

    // MARK: - Tiers

    private func tierOne(report: HealthReport, groups: [ProcessGroup], rules: ProtectionRules, now: Date) -> [ThrottleAction] {
        if let okSince, now.timeIntervalSince(okSince) >= config.restorePriorityCalmSeconds, !deprioritized.isEmpty {
            let actions = deprioritized.map { ThrottleAction.restorePriority($0.key, name: $0.value) }
            deprioritized.removeAll()
            return actions
        }

        // Background priority doesn't help when memory is the only problem.
        guard report.level >= .strained, report.cpuDriven || !report.memoryDriven else { return [] }

        var actions: [ThrottleAction] = []
        for group in eligible(groups, now: now) {
            for p in group.members where p.cpu >= config.deprioritizeMinCPU && !rules.isProtected(p) && deprioritized[p.key] == nil {
                deprioritized[p.key] = p.name
                actions.append(.deprioritize(p.key, name: p.name))
            }
        }
        return actions
    }

    private func tierTwo(report: HealthReport, groups: [ProcessGroup], rules: ProtectionRules, now: Date) -> ThrottleAction? {
        guard report.level >= .strained, now.timeIntervalSince(lastPause) >= config.pauseCooldown else { return nil }

        if report.level == .strained {
            let wait = report.memoryDriven ? config.memoryStrainSecondsBeforePause : config.cpuStrainSecondsBeforePause
            guard let strainedSince, now.timeIntervalSince(strainedSince) >= wait else { return nil }
        }

        let candidates = eligible(groups, now: now)
        let victim: ProcessGroup?
        let reason: String
        if report.memoryDriven {
            victim = candidates.filter { $0.memory >= config.pauseMinMemory }.max { $0.memory < $1.memory }
            reason = "largest memory user (\(ByteFormat.short(victim?.memory ?? 0)))"
        } else {
            victim = candidates.filter { $0.cpu >= config.pauseMinCPU }.max { $0.cpu < $1.cpu }
            reason = String(format: "largest CPU user (%.0f%%)", victim?.cpu ?? 0)
        }
        guard let victim else { return nil }

        let members = victim.members.filter { !rules.isProtected($0) }.map(\.key)
        guard !members.isEmpty else { return nil }

        let job = ThrottledJob(
            id: victim.id, name: victim.name, members: members, pausedAt: now,
            reason: ([reason] + report.reasons.prefix(2)).joined(separator: "; "),
            cpu: victim.cpu, memory: victim.memory
        )
        paused.append(job)
        pauseCounts[victim.id, default: 0] += 1
        lastPause = now
        strainedSince = now
        for key in members { deprioritized.removeValue(forKey: key) }
        return .pause(job)
    }

    private func nextResume(now: Date) -> ThrottleAction? {
        guard let calmSince, let oldest = paused.first,
              now.timeIntervalSince(lastResume) >= config.resumeSpacing,
              now.timeIntervalSince(lastPause) >= config.resumeSpacing else { return nil }

        let repeats = max(0, (pauseCounts[oldest.id] ?? 1) - 1)
        let required = min(config.resumeCalmSeconds * pow(2, Double(repeats)), config.maxResumeCalmSeconds)
        guard now.timeIntervalSince(calmSince) >= required else { return nil }

        paused.removeFirst()
        lastResume = now
        return .resume(oldest)
    }

    // MARK: - Helpers

    private func eligible(_ groups: [ProcessGroup], now: Date) -> [ProcessGroup] {
        let pausedIDs = Set(paused.map(\.id))
        return groups.filter { g in
            g.kind == .job && !g.isProtected && !g.anyStopped && !pausedIDs.contains(g.id)
                && (overrides[g.id].map { $0 <= now } ?? true)
        }
    }

    private func prune(groups: [ProcessGroup], now: Date) {
        let alive = Set(groups.flatMap { $0.members.map(\.key) })
        paused = paused.compactMap { job in
            let members = job.members.filter(alive.contains)
            guard !members.isEmpty else { return nil }
            return ThrottledJob(id: job.id, name: job.name, members: members, pausedAt: job.pausedAt,
                                reason: job.reason, cpu: job.cpu, memory: job.memory)
        }
        deprioritized = deprioritized.filter { alive.contains($0.key) }
        overrides = overrides.filter { $0.value > now }
    }
}
