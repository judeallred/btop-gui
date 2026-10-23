# Contributing to NoBeachballs

Thanks for helping out. A few things to know before you open a pull request.

## Contributor License Agreement

NoBeachballs is source-available (Prosperity Public License 3.0.0) and is also sold under commercial
licenses, which fund its development. To make that possible, every external contributor signs the
[Contributor License Agreement](CLA.md) once. You keep your copyright.

When you open your first pull request, a bot comments with a link to the CLA. Reply with the
sentence it asks for and the check turns green. Pull requests can't be merged until it passes.

## Development setup

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
make test     # unit + integration tests
make run      # build and open build/NoBeachballs.app
```

## Standards

- Keep `Sources/NoBeachballsCore` free of UI code; policy changes there need unit tests.
- Anything that pauses or deprioritizes a process must be recorded in the throttle ledger, so a
  crash never leaves processes frozen.
- No third-party dependencies without discussion; any that are added must be permissively licensed.
