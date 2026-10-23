import Darwin
import Foundation

/// Identifies a process across samples. PIDs get reused, so the start time is part of the identity.
public struct ProcessKey: Hashable, Codable, Sendable {
    public let pid: pid_t
    /// Process start time in microseconds since the epoch.
    public let startTime: UInt64

    public init(pid: pid_t, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessSample: Identifiable, Sendable {
    public var id: ProcessKey { key }
    public let key: ProcessKey
    public var pid: pid_t { key.pid }
    public let ppid: pid_t
    public let uid: uid_t
    /// Human-friendly name, e.g. "vite (node)" rather than "node".
    public let name: String
    public let executable: String
    public let command: String
    /// Percent of one core (can exceed 100).
    public let cpu: Double
    /// Physical footprint in bytes (what Activity Monitor calls "Memory").
    public let memory: UInt64
    /// Disk read + write, bytes per second.
    public let diskRate: Double
    public let threads: Int32
    public let isStopped: Bool
    /// False for processes owned by other users; their usage can't be read without root.
    public let isAccessible: Bool

    public init(key: ProcessKey, ppid: pid_t, uid: uid_t, name: String, executable: String, command: String,
                cpu: Double, memory: UInt64, diskRate: Double, threads: Int32, isStopped: Bool, isAccessible: Bool) {
        self.key = key
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.executable = executable
        self.command = command
        self.cpu = cpu
        self.memory = memory
        self.diskRate = diskRate
        self.threads = threads
        self.isStopped = isStopped
        self.isAccessible = isAccessible
    }
}

public enum MemoryPressure: Int, Codable, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

public struct SystemSample: Sendable {
    public let timestamp: Date
    /// 0...1 across all cores.
    public let cpuTotal: Double
    public let perCore: [Double]
    public let loadAverage: [Double]
    public let coreCount: Int
    public let memTotal: UInt64
    public let memUsed: UInt64
    public let memApp: UInt64
    public let memWired: UInt64
    public let memCompressed: UInt64
    /// kern.memorystatus_level: percent of memory the kernel considers available.
    public let memAvailablePercent: Int
    public let pressure: MemoryPressure
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    /// Bytes per second.
    public let swapOutRate: Double
    public let swapInRate: Double
    /// ProcessInfo.ThermalState raw value (0 nominal ... 3 critical).
    public let thermalState: Int

    public var loadPerCore: Double { coreCount > 0 ? (loadAverage.first ?? 0) / Double(coreCount) : 0 }
}

public enum ByteFormat {
    public static func short(_ bytes: UInt64) -> String { short(Double(bytes)) }

    public static func short(_ bytes: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = bytes
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value))B" }
        return value >= 100 ? String(format: "%.0f%@", value, units[unit]) : String(format: "%.1f%@", value, units[unit])
    }
}
