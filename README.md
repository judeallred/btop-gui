# NoBeachballs

A macOS menu bar app that answers one question fast: **what is slowing my Mac down, and can I pause or kill it?**
It also auto-throttles runaway jobs *before* the UI starts beachballing, which matters if you run lots of parallel AI agents, builds and test suites.

- **Menu bar icon**: a gauge whose needle follows load (CPU or memory, whichever is closer to running out). A badge in its corner flags trouble:
  - no badge: Calm or Choppy
  - teal tortoise: auto-throttle is holding something back
  - orange ⚠︎: Rough (the phase right before beachballs; auto-throttle acts here)
  - red ⚠︎: Beachball (the system is lagging)
- **Click** for a btop-style view: CPU and per-core meters, memory/pressure/swap, scheduling delay, the top CPU and top memory consumer with **Pause / Kill** buttons, and a full process list.
- **Right-click** for quick actions: auto-throttle mode, resume everything, launch at login, quit.

## Install

Download `NoBeachballs-<version>.zip` from the [latest release](https://github.com/judeallred/nobeachballs/releases/latest),
unzip it, move **NoBeachballs.app** to Applications and open it. It runs on macOS 14 or later, Apple silicon or Intel.

Until releases are signed with a Developer ID, macOS blocks the first launch. To allow it, open
**System Settings → Privacy & Security** and click **Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/NoBeachballs.app`.

### Build from source

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
git clone git@github.com:judeallred/nobeachballs.git
cd nobeachballs
make install      # builds, installs to /Applications, launches
```

Enable **Launch at login** from the gear menu or the right-click menu.

## Processes are grouped into jobs

Parallel AI work creates hundreds of small processes, so judging them one at a time is useless. NoBeachballs groups them:

- **Apps**: an app plus all its helpers (Chrome's 45 renderers count as one "Google Chrome" row).
- **Jobs**: command-line process trees. A job starts at the topmost process below a shell or app. For example, `claude → zsh → npm run build → node` produces a `claude` job and a separate `npm` job, so you can pause the build without freezing the agent (or the reverse).
- Interpreters get readable names: `vite (node)`, `pytest (python)`, `claude` instead of `node` and `2.1.309`.

Pause and kill act on the whole group. Expand a group to act on individual processes.

## How lag is detected

Several signals are combined, with hysteresis: health rises quickly and falls only after several calm samples.

| Signal | Rough | Beachball |
|---|---|---|
| Scheduling delay of a high-priority thread | ≥ 40 ms | ≥ 150 ms |
| Paging memory back in (swap-in) | ≥ 24 MB/s | ≥ 96 MB/s |
| Swapping out | ≥ 8 MB/s with pressure warning | ≥ 48 MB/s |
| Memory available (`kern.memorystatus_level`) | ≤ 10% | pressure critical |
| CPU | ≥ 92% sustained, or load ≥ 1.5× cores | |
| Thermal state | serious | critical |

Swap-in is the classic beachball: an app touches memory that was swapped out and stalls while it is read back.

## Auto-throttle

Pick a mode in the header or the right-click menu:

- **Off**: never touches anything.
- **Deprioritize**: when strained by CPU, processes above 30% CPU get background priority (`PRIO_DARWIN_BG`: efficiency cores, throttled I/O). Nothing stops, and the change is fully reversible.
- **Deprioritize + Pause** (default): additionally pauses (`SIGSTOP`) the heaviest job when:
  - the system is lagging, or
  - CPU strain lasts 20 s after deprioritizing, or
  - memory strain lasts 8 s (deprioritizing does nothing for memory).

  Memory-driven pauses pick the largest job of at least 1 GB. CPU-driven pauses pick the busiest job using at least one full core.

Recovery:

- Once things are calm for 20 s, paused jobs resume one at a time, oldest first.
- A job that keeps getting re-paused waits twice as long each time (up to 10 min). This is effectively a queue.
- Priorities are restored after 30 s of OK.
- If you resume something by hand, auto-throttle leaves it alone for 5 minutes.

What is never touched automatically:

- GUI apps and their helpers (pausing them makes them beachball, which is what we are trying to avoid)
- system and root processes
- this app
- anything you mark **Never auto-throttle** from a row's `…` menu

You can still pause or kill any of these manually.

### Safety

- Everything paused or deprioritized is written to `~/Library/Application Support/NoBeachballs/throttled.json`.
- Quitting, `SIGTERM`, logout, and turning auto-throttle off all resume everything. If the app crashes or is force-killed, the next launch resumes whatever the file lists.
- Processes are tracked by PID *and* start time, so a recycled PID is never signalled.

### Caveats

- **Pausing stops CPU and memory growth immediately, but doesn't free RAM.** The kernel compresses or swaps out a paused job's memory over time, which relieves pressure on everything else. To get memory back immediately, kill it.
- A paused AI agent can't keep its network connection alive. Long pauses may surface as an API timeout or retry when it resumes.
- Without root, macOS doesn't expose per-process usage for root-owned daemons. Their total is shown as "system cpu".

## Develop

```sh
make test     # unit + integration tests
make app      # build/NoBeachballs.app
make run      # build and open
build/NoBeachballs.app/Contents/MacOS/NoBeachballs --snapshot out.png        # render the window to a PNG
build/NoBeachballs.app/Contents/MacOS/NoBeachballs --icon-snapshot icons.png # render every icon state
```

Layout:

- `Sources/NoBeachballsCore`: sampling (libproc/mach), health evaluation, grouping, the throttle engine. No UI.
- `Sources/NoBeachballs`: menu bar item, popover, SwiftUI views.

## License

[MIT](LICENSE). Contributions welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
