import Darwin
import Foundation

public enum ProcessControl {
    /// True if `key` still refers to the same process (guards against PID reuse).
    public static func isAlive(_ key: ProcessKey) -> Bool {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(key.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec) == key.startTime
    }

    /// Sends `signal` to each live process. Returns how many succeeded.
    @discardableResult
    public static func send(_ signal: Int32, to keys: [ProcessKey]) -> Int {
        keys.reduce(0) { count, key in
            isAlive(key) && kill(key.pid, signal) == 0 ? count + 1 : count
        }
    }

    /// Background priority: E-cores only, throttled disk and network I/O. Fully reversible.
    @discardableResult
    public static func setBackground(_ key: ProcessKey, _ background: Bool) -> Bool {
        guard isAlive(key) else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(key.pid), background ? PRIO_DARWIN_BG : 0) == 0
    }
}

/// Everything this app has paused or deprioritized, persisted so that a crash or force-quit
/// never leaves processes frozen: the next launch undoes whatever is listed here.
public struct ThrottleLedger: Codable, Sendable, Equatable {
    public var paused: [ProcessKey] = []
    public var deprioritized: [ProcessKey] = []

    public init(paused: [ProcessKey] = [], deprioritized: [ProcessKey] = []) {
        self.paused = paused
        self.deprioritized = deprioritized
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("nobeachballs/throttled.json")
    }

    public static func load(from url: URL = defaultURL) -> ThrottleLedger {
        guard let data = try? Data(contentsOf: url) else { return ThrottleLedger() }
        return (try? JSONDecoder().decode(ThrottleLedger.self, from: data)) ?? ThrottleLedger()
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Resumes and re-prioritizes everything listed, then clears the file.
    @discardableResult
    public static func releaseAll(at url: URL = defaultURL) -> Int {
        let ledger = load(from: url)
        let resumed = ProcessControl.send(SIGCONT, to: ledger.paused)
        for key in ledger.deprioritized { ProcessControl.setBackground(key, false) }
        ThrottleLedger().save(to: url)
        return resumed
    }
}
