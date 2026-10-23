import Foundation

public enum HealthLevel: Int, Comparable, Codable, Sendable {
    /// Plenty of headroom.
    case ok
    /// Busy but fine. Informational only.
    case elevated
    /// The phase before the UI starts stalling. Auto-throttle acts here.
    case strained
    /// The UI is (or is about to be) visibly lagging. The menu bar icon shows a warning.
    case lagging

    public static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .ok: "OK"
        case .elevated: "Busy"
        case .strained: "Strained"
        case .lagging: "Lagging"
        }
    }
}

public struct HealthInputs: Sendable {
    public var cpuTotal: Double
    public var loadPerCore: Double
    public var pressure: MemoryPressure
    public var memAvailablePercent: Int
    public var swapOutRate: Double
    public var swapInRate: Double
    public var latencyMs: Double
    public var thermalState: Int

    public init(cpuTotal: Double = 0, loadPerCore: Double = 0, pressure: MemoryPressure = .normal,
                memAvailablePercent: Int = 100, swapOutRate: Double = 0, swapInRate: Double = 0,
                latencyMs: Double = 0, thermalState: Int = 0) {
        self.cpuTotal = cpuTotal
        self.loadPerCore = loadPerCore
        self.pressure = pressure
        self.memAvailablePercent = memAvailablePercent
        self.swapOutRate = swapOutRate
        self.swapInRate = swapInRate
        self.latencyMs = latencyMs
        self.thermalState = thermalState
    }

    public init(system: SystemSample, latencyMs: Double) {
        self.init(cpuTotal: system.cpuTotal, loadPerCore: system.loadPerCore, pressure: system.pressure,
                  memAvailablePercent: system.memAvailablePercent, swapOutRate: system.swapOutRate,
                  swapInRate: system.swapInRate, latencyMs: latencyMs, thermalState: system.thermalState)
    }
}

public struct HealthReport: Sendable, Equatable {
    public var level: HealthLevel
    public var reasons: [String]
    /// Memory (pressure, swapping) is a cause. Pausing helps; deprioritizing doesn't.
    public var memoryDriven: Bool
    /// CPU contention is a cause. Deprioritizing helps.
    public var cpuDriven: Bool

    public static let ok = HealthReport(level: .ok, reasons: [], memoryDriven: false, cpuDriven: false)
}

public struct HealthThresholds: Sendable {
    public var cpuElevated = 0.75
    public var cpuStrained = 0.92
    public var loadPerCoreStrained = 1.5
    public var memAvailableElevated = 25
    public var memAvailableStrained = 10
    public var swapOutStrained: Double = 8 * 1024 * 1024
    public var swapOutLagging: Double = 48 * 1024 * 1024
    /// Swap-ins are apps faulting swapped-out memory back in: the classic beachball.
    public var swapInStrained: Double = 24 * 1024 * 1024
    public var swapInLagging: Double = 96 * 1024 * 1024
    public var latencyStrainedMs = 40.0
    public var latencyLaggingMs = 150.0

    public init() {}
}

/// Classifies samples into a health level, with hysteresis so the icon and the throttler
/// don't flap: rising is fast, falling requires several calm samples in a row.
public final class HealthEvaluator {
    public let thresholds: HealthThresholds
    private let calmSamplesToDrop: Int
    private var recent: [HealthLevel] = []
    private var current: HealthLevel = .ok
    private var currentReasons: [String] = []
    private var calmStreak = 0

    public init(thresholds: HealthThresholds = HealthThresholds(), calmSamplesToDrop: Int = 5) {
        self.thresholds = thresholds
        self.calmSamplesToDrop = calmSamplesToDrop
    }

    public func evaluate(_ inputs: HealthInputs) -> HealthReport {
        var raw = Self.classify(inputs, thresholds)

        recent.append(raw.level)
        if recent.count > 3 { recent.removeFirst() }

        // A single spiky sample shouldn't trigger throttling; require 2 of the last 3.
        var target = raw.level
        if target == .strained, recent.filter({ $0 >= .strained }).count < 2 { target = .elevated }

        if target >= current {
            current = target
            currentReasons = raw.reasons
            calmStreak = 0
        } else {
            calmStreak += 1
            if calmStreak >= calmSamplesToDrop {
                current = max(target, HealthLevel(rawValue: current.rawValue - 1) ?? .ok)
                calmStreak = 0
            }
        }

        if raw.level < current {
            raw.reasons = currentReasons.map { "\($0) (easing)" } + raw.reasons.filter { !currentReasons.contains($0) }
        }
        raw.level = current
        return raw
    }

    public static func classify(_ i: HealthInputs, _ t: HealthThresholds) -> HealthReport {
        var level = HealthLevel.ok
        var reasons: [String] = []
        var memory = false
        var cpu = false

        func raise(_ to: HealthLevel, _ reason: String, memory isMemory: Bool = false, cpu isCPU: Bool = false) {
            level = max(level, to)
            reasons.append(reason)
            if isMemory { memory = true }
            if isCPU { cpu = true }
        }

        let swapMB = String(format: "%.0f MB/s", i.swapOutRate / 1024 / 1024)

        if i.latencyMs >= t.latencyLaggingMs {
            raise(.lagging, String(format: "scheduling stalls of %.0f ms", i.latencyMs), cpu: !(i.pressure > .normal))
        } else if i.latencyMs >= t.latencyStrainedMs {
            raise(.strained, String(format: "scheduling delays of %.0f ms", i.latencyMs), cpu: !(i.pressure > .normal))
        }

        if i.pressure == .critical {
            raise(.lagging, "memory pressure critical", memory: true)
        } else if i.swapOutRate >= t.swapOutLagging {
            raise(.lagging, "heavy swapping (\(swapMB))", memory: true)
        } else if i.memAvailablePercent <= t.memAvailableStrained {
            raise(.strained, "only \(i.memAvailablePercent)% memory available", memory: true)
        } else if i.pressure == .warning, i.swapOutRate >= t.swapOutStrained {
            raise(.strained, "memory pressure + swapping (\(swapMB))", memory: true)
        } else if i.pressure == .warning || i.memAvailablePercent <= t.memAvailableElevated {
            raise(.elevated, "memory getting tight (\(i.memAvailablePercent)% available)", memory: true)
        }

        let swapInMB = String(format: "%.0f MB/s", i.swapInRate / 1024 / 1024)
        if i.swapInRate >= t.swapInLagging {
            raise(.lagging, "paging memory back in (\(swapInMB))", memory: true)
        } else if i.swapInRate >= t.swapInStrained {
            raise(.strained, "paging memory back in (\(swapInMB))", memory: true)
        }

        if i.cpuTotal >= t.cpuStrained {
            raise(.strained, String(format: "CPU %.0f%%", i.cpuTotal * 100), cpu: true)
        } else if i.loadPerCore >= t.loadPerCoreStrained {
            raise(.strained, String(format: "run queue %.1f× cores", i.loadPerCore), cpu: true)
        } else if i.cpuTotal >= t.cpuElevated {
            raise(.elevated, String(format: "CPU %.0f%%", i.cpuTotal * 100), cpu: true)
        }

        if i.thermalState >= 3 {
            raise(.lagging, "thermal throttling (critical)", cpu: true)
        } else if i.thermalState == 2 {
            raise(.strained, "thermal throttling", cpu: true)
        }

        return HealthReport(level: level, reasons: reasons, memoryDriven: memory, cpuDriven: cpu)
    }
}
