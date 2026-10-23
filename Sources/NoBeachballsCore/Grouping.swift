import Darwin
import Foundation

/// Decides which processes must never be paused or deprioritized automatically.
public struct ProtectionRules: Sendable {
    public var ownPID: pid_t
    public var uid: uid_t
    /// Bundle paths of running GUI apps, each ending in "/".
    public var appBundlePaths: [String]
    /// Lowercased process names the user never wants auto-throttled.
    public var protectedNames: Set<String>

    public static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    public static let defaultProtectedNames: Set<String> = [
        "windowserver", "dock", "finder", "systemuiserver", "loginwindow", "controlcenter", "coreaudiod",
        "launchd", "kernel_task", "sshd", "ssh-agent", "gpg-agent", "1password",
    ]

    public init(ownPID: pid_t = getpid(), uid: uid_t = getuid(), appBundlePaths: [String] = [], protectedNames: Set<String> = []) {
        self.ownPID = ownPID
        self.uid = uid
        self.appBundlePaths = appBundlePaths
        self.protectedNames = protectedNames
    }

    /// The running app bundle this process is part of (the app itself or one of its helpers).
    /// Tools that merely ship inside a bundle (Xcode's compilers, bundled ripgrep) don't count.
    public func appBundle(for p: ProcessSample) -> String? {
        guard !p.executable.isEmpty else { return nil }
        for bundle in appBundlePaths where p.executable.hasPrefix(bundle) {
            let inner = p.executable.dropFirst(bundle.count)
            if inner.contains("Contents/Developer/") || inner.hasPrefix("Contents/Resources/") { return nil }
            return bundle
        }
        return nil
    }

    public func isSystem(_ p: ProcessSample) -> Bool {
        !p.isAccessible || p.uid != uid || p.pid <= 1 || p.executable.isEmpty
            || Self.systemPrefixes.contains(where: p.executable.hasPrefix)
    }

    public func isProtected(_ p: ProcessSample) -> Bool {
        if p.pid == ownPID || isSystem(p) || appBundle(for: p) != nil { return true }
        let base = (p.executable as NSString).lastPathComponent.lowercased()
        let names = protectedNames.union(Self.defaultProtectedNames)
        return names.contains(base) || names.contains(p.name.lowercased())
    }
}

public struct ProcessTree: Sendable {
    public let byPID: [pid_t: ProcessSample]
    public let children: [pid_t: [pid_t]]

    public init(_ processes: [ProcessSample]) {
        var byPID: [pid_t: ProcessSample] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for p in processes {
            byPID[p.pid] = p
            children[p.ppid, default: []].append(p.pid)
        }
        self.byPID = byPID
        self.children = children
    }

    /// The process and all of its descendants.
    public func subtree(of pid: pid_t) -> [ProcessSample] {
        var result: [ProcessSample] = []
        var stack = [pid]
        var visited = Set<pid_t>()
        while let next = stack.popLast() {
            guard visited.insert(next).inserted, let p = byPID[next] else { continue }
            result.append(p)
            stack.append(contentsOf: children[next] ?? [])
        }
        return result
    }
}

/// A unit the user thinks about: an app with its helpers, or a command-line job tree.
public struct ProcessGroup: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case app(bundlePath: String)
        case job
        case system
    }

    public let id: String
    public let kind: Kind
    public let root: ProcessSample
    /// Sorted by CPU, descending.
    public let members: [ProcessSample]
    public let isProtected: Bool
    public let cpu: Double
    public let memory: UInt64
    public let diskRate: Double

    public var name: String {
        if case .app(let bundle) = kind {
            return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return root.name
    }

    public var isStopped: Bool { !members.isEmpty && members.allSatisfy(\.isStopped) }
    public var anyStopped: Bool { members.contains(where: \.isStopped) }

    public init(id: String, kind: Kind, root: ProcessSample, members: [ProcessSample], isProtected: Bool) {
        self.id = id
        self.kind = kind
        self.root = root
        self.members = members.sorted { $0.cpu > $1.cpu }
        self.isProtected = isProtected
        cpu = members.reduce(0) { $0 + $1.cpu }
        memory = members.reduce(0) { $0 + $1.memory }
        diskRate = members.reduce(0) { $0 + $1.diskRate }
    }
}

public enum Grouping {
    /// Processes that start jobs rather than being part of one. A job's root is the topmost
    /// process below one of these, so "claude → zsh → npm run build → node" yields a
    /// separate "npm" job that can be paused while the agent itself keeps running.
    public static let launchers: Set<String> = ProcessSampler.shells.union(["login", "tmux", "screen", "launchd", "sshd", "sudo", "su"])

    public static func groups(_ processes: [ProcessSample], tree: ProcessTree, rules: ProtectionRules) -> [ProcessGroup] {
        var buckets: [String: (kind: ProcessGroup.Kind, members: [ProcessSample])] = [:]

        for p in processes {
            let (id, kind) = groupID(for: p, tree: tree, rules: rules)
            buckets[id, default: (kind, [])].members.append(p)
        }

        return buckets.map { id, bucket in
            let root: ProcessSample
            switch bucket.kind {
            case .app(let bundle):
                // The main app process: inside Contents/MacOS with a parent outside the bundle.
                root = bucket.members.first { p in
                    p.executable.hasPrefix(bundle + "Contents/MacOS/")
                        && !(tree.byPID[p.ppid]?.executable.hasPrefix(bundle) ?? false)
                } ?? bucket.members.min { $0.key.startTime < $1.key.startTime }!
            case .job, .system:
                root = bucket.members.first { "\($0.pid)" == id.split(separator: ":").last.map(String.init) }
                    ?? bucket.members[0]
            }
            let isProtected: Bool
            switch bucket.kind {
            case .app, .system: isProtected = true
            case .job: isProtected = rules.isProtected(root)
            }
            return ProcessGroup(id: id, kind: bucket.kind, root: root, members: bucket.members, isProtected: isProtected)
        }
    }

    static func groupID(for p: ProcessSample, tree: ProcessTree, rules: ProtectionRules) -> (String, ProcessGroup.Kind) {
        if rules.isSystem(p) { return ("system:\(p.pid)", .system) }
        if let bundle = rules.appBundle(for: p) { return ("app:\(bundle)", .app(bundlePath: bundle)) }
        let root = jobRoot(for: p, tree: tree, rules: rules)
        return ("job:\(root.key.startTime):\(root.pid)", .job)
    }

    public static func jobRoot(for p: ProcessSample, tree: ProcessTree, rules: ProtectionRules) -> ProcessSample {
        var current = p
        var hops = 0
        while hops < 64, let parent = tree.byPID[current.ppid], !isBoundary(parent, rules: rules) {
            current = parent
            hops += 1
        }
        return current
    }

    static func isBoundary(_ p: ProcessSample, rules: ProtectionRules) -> Bool {
        if rules.isSystem(p) || rules.appBundle(for: p) != nil || p.pid == rules.ownPID { return true }
        let base = (p.executable as NSString).lastPathComponent
        return launchers.contains(base.hasPrefix("-") ? String(base.dropFirst()) : base)
    }
}
