import Darwin
import Foundation

/// Samples every process via libproc. Not thread-safe; call from one serial queue.
public final class ProcessSampler {
    private struct Counters {
        let cpuNanos: UInt64
        let diskBytes: UInt64
    }

    private struct Identity {
        let name: String
        let executable: String
        let command: String
    }

    private var previous: [ProcessKey: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var identities: [ProcessKey: Identity] = [:]
    private let timebase: mach_timebase_info_data_t
    private var pidBuffer = [pid_t](repeating: 0, count: 8192)
    private var argsBuffer: [UInt8]

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb

        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        sysctl(&mib, 2, &argmax, &size, nil, 0)
        argsBuffer = [UInt8](repeating: 0, count: Int(max(argmax, 4096)))
    }

    public func sample() -> [ProcessSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime)

        let bytes = proc_listallpids(&pidBuffer, Int32(pidBuffer.count * MemoryLayout<pid_t>.size))
        let count = Int(max(bytes, 0))

        var result: [ProcessSample] = []
        result.reserveCapacity(count)
        var nextCounters: [ProcessKey: Counters] = [:]
        nextCounters.reserveCapacity(count)
        var seen = Set<ProcessKey>()

        for pid in pidBuffer.prefix(count) where pid > 0 {
            var bsd = proc_bsdinfo()
            let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard got == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }

            let key = ProcessKey(pid: pid, startTime: UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
            seen.insert(key)

            var usage = rusage_info_v4()
            let usageOK = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0

            var cpu = 0.0
            var disk = 0.0
            var memory: UInt64 = 0
            if usageOK {
                // ri_*_time is in mach ticks on Apple Silicon despite being documented as nanoseconds.
                let cpuNanos = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
                let diskBytes = usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
                memory = usage.ri_phys_footprint
                if elapsed > 0, let prev = previous[key] {
                    cpu = Double(cpuNanos &- prev.cpuNanos) / elapsed * 100
                    disk = Double(diskBytes &- prev.diskBytes) / (elapsed / 1e9)
                    if cpu < 0 || cpu.isNaN { cpu = 0 }
                    if disk < 0 || disk.isNaN { disk = 0 }
                }
                nextCounters[key] = Counters(cpuNanos: cpuNanos, diskBytes: diskBytes)
            }

            var threads: Int32 = 0
            var task = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                threads = task.pti_threadnum
            }

            let identity = identities[key] ?? resolveIdentity(pid: pid, bsd: &bsd)
            identities[key] = identity

            result.append(ProcessSample(
                key: key,
                ppid: pid_t(bsd.pbi_ppid),
                uid: bsd.pbi_uid,
                name: identity.name,
                executable: identity.executable,
                command: identity.command,
                cpu: cpu,
                memory: memory,
                diskRate: disk,
                threads: threads,
                isStopped: bsd.pbi_status == UInt32(SSTOP),
                isAccessible: usageOK
            ))
        }

        previous = nextCounters
        previousTime = now
        identities = identities.filter { seen.contains($0.key) }
        return result
    }

    private func resolveIdentity(pid: pid_t, bsd: inout proc_bsdinfo) -> Identity {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executable = pathLength > 0 ? String(cString: pathBuffer) : ""

        let bsdName = Self.string(fromTuple: &bsd.pbi_name)
        let comm = Self.string(fromTuple: &bsd.pbi_comm)
        let base = executable.isEmpty ? (bsdName.isEmpty ? comm : bsdName) : (executable as NSString).lastPathComponent

        let args = arguments(pid: pid) ?? []
        let command = args.isEmpty ? executable : String(args.joined(separator: " ").prefix(600))
        return Identity(name: Self.displayName(base: base, args: args), executable: executable, command: command)
    }

    /// Reads argv via KERN_PROCARGS2. Only works for processes owned by the current user.
    private func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argsBuffer.count
        guard sysctl(&mib, 3, &argsBuffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = argsBuffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, argsBuffer[i] != 0 { i += 1 } // exec path
        while i < size, argsBuffer[i] == 0 { i += 1 } // padding

        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, argsBuffer[i] != 0 { i += 1 }
            args.append(String(decoding: argsBuffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func string<T>(fromTuple tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "Python", "ruby", "perl", "java", "php", "uv", "npx",
    ]
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]

    /// Turns "node /path/to/vite build" into "vite (node)" so AI tooling is identifiable.
    public static func displayName(base: String, args: [String]) -> String {
        // Versioned binaries (~/.local/bin/claude → versions/2.1.309) are better known by argv[0].
        if base.allSatisfy({ $0.isNumber || $0 == "." }), let argv0 = args.first, !argv0.isEmpty {
            return displayName(base: (argv0 as NSString).lastPathComponent, args: args)
        }
        let interpreter = base.lowercased().hasPrefix("python") ? "python" : base
        if interpreters.contains(base) || interpreter == "python" {
            var rest = args.dropFirst().makeIterator()
            while let arg = rest.next() {
                if arg == "-m", let module = rest.next() { return "\(module) (\(interpreter))" }
                if arg == "-c" || arg == "-e" || arg == "--eval" { return "\(interpreter) \(arg)" }
                if arg.hasPrefix("-") { continue }
                var script = (arg as NSString).lastPathComponent
                for ext in [".js", ".mjs", ".cjs", ".ts", ".py"] where script.hasSuffix(ext) {
                    script = String(script.dropLast(ext.count))
                }
                // Generic entry points ("index", "cli", "main") say less than their package directory.
                if ["index", "cli", "main", "run"].contains(script) {
                    var dir = (arg as NSString).deletingLastPathComponent as NSString
                    while ["bin", "dist", "lib", "build", "src", "out", "esm", "cjs"].contains(dir.lastPathComponent) {
                        dir = dir.deletingLastPathComponent as NSString
                    }
                    if !dir.lastPathComponent.isEmpty, dir.lastPathComponent != "/" { script = dir.lastPathComponent }
                }
                return script.isEmpty ? interpreter : "\(script) (\(interpreter))"
            }
            return interpreter
        }
        if shells.contains(base), let flag = args.firstIndex(of: "-c"), flag + 1 < args.count {
            return "\(base): " + String(args[flag + 1].prefix(48))
        }
        return base
    }
}
