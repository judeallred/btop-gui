import XCTest
@testable import NoBeachballsCore

final class HealthTests: XCTestCase {
    func testCalmSystemIsOK() {
        let r = HealthEvaluator.classify(HealthInputs(cpuTotal: 0.3), HealthThresholds())
        XCTAssertEqual(r.level, .ok)
    }

    func testPressureWarningAloneIsOnlyElevated() {
        let r = HealthEvaluator.classify(HealthInputs(pressure: .warning, memAvailablePercent: 23), HealthThresholds())
        XCTAssertEqual(r.level, .elevated)
        XCTAssertTrue(r.memoryDriven)
    }

    func testPressureWithSwappingIsStrained() {
        let r = HealthEvaluator.classify(HealthInputs(pressure: .warning, memAvailablePercent: 20, swapOutRate: 20e6), HealthThresholds())
        XCTAssertEqual(r.level, .strained)
    }

    func testUIStallIsLagging() {
        let r = HealthEvaluator.classify(HealthInputs(latencyMs: 800), HealthThresholds())
        XCTAssertEqual(r.level, .lagging)
    }

    func testSingleSpikeDoesNotStrain() {
        let e = HealthEvaluator()
        XCTAssertEqual(e.evaluate(HealthInputs(cpuTotal: 0.97)).level, .elevated)
        XCTAssertEqual(e.evaluate(HealthInputs(cpuTotal: 0.97)).level, .strained)
    }

    func testRecoveryNeedsSeveralCalmSamples() {
        let e = HealthEvaluator(calmSamplesToDrop: 3)
        _ = e.evaluate(HealthInputs(latencyMs: 900))
        XCTAssertEqual(e.evaluate(HealthInputs()).level, .lagging)
        XCTAssertEqual(e.evaluate(HealthInputs()).level, .lagging)
        let easing = e.evaluate(HealthInputs())
        XCTAssertEqual(easing.level, .strained)
        XCTAssertEqual(easing.reasons, ["scheduling stalls of 900 ms (easing)"])
    }

    func testSwapInIsAMemorySignal() {
        let r = HealthEvaluator.classify(HealthInputs(swapInRate: 40e6), HealthThresholds())
        XCTAssertEqual(r.level, .strained)
        XCTAssertTrue(r.memoryDriven)
    }
}

final class NamingTests: XCTestCase {
    func testInterpreterScriptsAreNamedByScript() {
        XCTAssertEqual(ProcessSampler.displayName(base: "node", args: ["node", "--max-old-space-size=4096", "/x/node_modules/.bin/vite", "build"]), "vite (node)")
        XCTAssertEqual(ProcessSampler.displayName(base: "python3.14", args: ["python3", "-m", "pytest"]), "pytest (python)")
        XCTAssertEqual(ProcessSampler.displayName(base: "node", args: ["node", "/x/tsc/lib/index.js"]), "tsc (node)")
        XCTAssertEqual(ProcessSampler.displayName(base: "zsh", args: ["zsh", "-c", "npm test"]), "zsh: npm test")
        XCTAssertEqual(ProcessSampler.displayName(base: "cargo", args: ["cargo", "build"]), "cargo")
        XCTAssertEqual(ProcessSampler.displayName(base: "2.1.309", args: ["/Users/me/.local/bin/claude", "-p"]), "claude")
    }
}

final class ThrottleTests: XCTestCase {
    let uid = getuid()
    var nextPID: pid_t = 1000

    func proc(_ name: String, ppid: pid_t, cpu: Double = 0, mem: UInt64 = 0, exe: String? = nil) -> ProcessSample {
        nextPID += 1
        return ProcessSample(key: ProcessKey(pid: nextPID, startTime: UInt64(nextPID)), ppid: ppid, uid: uid, name: name,
                             executable: exe ?? "/usr/local/bin/\(name)", command: name, cpu: cpu, memory: mem,
                             diskRate: 0, threads: 1, isStopped: false, isAccessible: true)
    }

    func groups(_ ps: [ProcessSample], rules: ProtectionRules) -> [ProcessGroup] {
        Grouping.groups(ps, tree: ProcessTree(ps), rules: rules)
    }

    func testJobsSplitAtShells() {
        let rules = ProtectionRules(ownPID: 1, uid: uid, appBundlePaths: ["/Applications/T3.app/"])
        let app = proc("T3", ppid: 1, exe: "/Applications/T3.app/Contents/MacOS/T3")
        let claude = proc("claude", ppid: app.pid)
        let shell = proc("zsh", ppid: claude.pid, exe: "/bin/zsh")
        let npm = proc("npm", ppid: shell.pid)
        let node = proc("vite (node)", ppid: npm.pid, cpu: 300)
        let gs = groups([app, claude, shell, npm, node], rules: rules)

        let job = gs.first { $0.members.contains { $0.pid == node.pid } }!
        XCTAssertEqual(job.root.pid, npm.pid)
        XCTAssertEqual(job.members.count, 2)
        XCTAssertFalse(job.isProtected)
        XCTAssertTrue(gs.first { $0.root.pid == app.pid }!.isProtected)
    }

    func testMemoryStrainPausesLargestJobThenResumesWhenCalm() {
        let rules = ProtectionRules(ownPID: 1, uid: uid)
        let big = proc("bigjob", ppid: 1, mem: 6 << 30)
        let small = proc("smalljob", ppid: 1, mem: 2 << 30)
        let gs = groups([big, small], rules: rules)

        var config = ThrottleConfig()
        config.memoryStrainSecondsBeforePause = 5
        config.resumeCalmSeconds = 10
        config.resumeSpacing = 0
        let engine = ThrottleEngine(config: config)
        let strained = HealthReport(level: .strained, reasons: ["swap"], memoryDriven: true, cpuDriven: false)
        let t0 = Date()

        XCTAssertEqual(engine.step(report: strained, groups: gs, rules: rules, now: t0), [])
        let actions = engine.step(report: strained, groups: gs, rules: rules, now: t0 + 6)
        guard case .pause(let job) = actions.first else { return XCTFail("expected pause, got \(actions)") }
        XCTAssertEqual(job.members, [big.key])

        XCTAssertEqual(engine.step(report: .ok, groups: gs, rules: rules, now: t0 + 7), [])
        let later = engine.step(report: .ok, groups: gs, rules: rules, now: t0 + 18)
        XCTAssertEqual(later, [.resume(job)])
    }

    func testProtectedAndAppProcessesAreNeverThrottled() {
        let rules = ProtectionRules(ownPID: 1, uid: uid, appBundlePaths: ["/Applications/Chrome.app/"], protectedNames: ["ollama"])
        let chrome = proc("Chrome", ppid: 1, cpu: 900, mem: 9 << 30, exe: "/Applications/Chrome.app/Contents/MacOS/Chrome")
        let ollama = proc("ollama", ppid: 1, cpu: 900, mem: 9 << 30)
        let gs = groups([chrome, ollama], rules: rules)
        let engine = ThrottleEngine()
        let lagging = HealthReport(level: .lagging, reasons: [], memoryDriven: true, cpuDriven: true)
        XCTAssertEqual(engine.step(report: lagging, groups: gs, rules: rules), [])
    }

    func testCPUStrainDeprioritizesFirst() {
        let rules = ProtectionRules(ownPID: 1, uid: uid)
        let hog = proc("cargo", ppid: 1, cpu: 800)
        let gs = groups([hog], rules: rules)
        let engine = ThrottleEngine()
        let strained = HealthReport(level: .strained, reasons: [], memoryDriven: false, cpuDriven: true)
        XCTAssertEqual(engine.step(report: strained, groups: gs, rules: rules), [.deprioritize(hog.key, name: "cargo")])
    }

    func testOffModeReleasesEverything() {
        let rules = ProtectionRules(ownPID: 1, uid: uid)
        let hog = proc("cargo", ppid: 1, cpu: 800)
        let gs = groups([hog], rules: rules)
        let engine = ThrottleEngine()
        let strained = HealthReport(level: .strained, reasons: [], memoryDriven: false, cpuDriven: true)
        _ = engine.step(report: strained, groups: gs, rules: rules)
        engine.config.mode = .off
        XCTAssertEqual(engine.step(report: strained, groups: gs, rules: rules), [.restorePriority(hog.key, name: "cargo")])
        XCTAssertFalse(engine.isThrottling)
    }
}

/// Exercises real signals against a throwaway child process.
final class ProcessControlIntegrationTests: XCTestCase {
    func testPauseIsVisibleAndLedgerReleaseResumes() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        try child.run()
        defer { child.terminate() }

        let sampler = ProcessSampler()
        func current() -> ProcessSample? { sampler.sample().first { $0.pid == child.processIdentifier } }
        let key = try XCTUnwrap(current()).key

        XCTAssertTrue(ProcessControl.setBackground(key, true))
        XCTAssertEqual(ProcessControl.send(SIGSTOP, to: [key]), 1)
        usleep(100_000)
        XCTAssertEqual(current()?.isStopped, true)

        // Simulate a crash: the ledger on disk is all that's left, and a fresh launch releases it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID()).json")
        ThrottleLedger(paused: [key], deprioritized: [key]).save(to: url)
        XCTAssertEqual(ThrottleLedger.releaseAll(at: url), 1)
        usleep(100_000)
        XCTAssertEqual(current()?.isStopped, false)
        XCTAssertTrue(ThrottleLedger.load(from: url).paused.isEmpty)

        // A recycled PID with a different start time must never be signalled.
        let stale = ProcessKey(pid: key.pid, startTime: key.startTime + 1)
        XCTAssertEqual(ProcessControl.send(SIGSTOP, to: [stale]), 0)
    }
}
