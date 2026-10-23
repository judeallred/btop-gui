# Contributing to NoBeachballs

Thanks for helping out. A few things to know before you open a pull request.

Contributions are licensed under the [MIT License](LICENSE), the same as the project.

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

## Releasing

Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then push a matching tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The Release workflow builds a universal `NoBeachballs.app` and publishes it as a GitHub release.
It signs and notarizes the app once the Developer ID secrets listed in
`.github/workflows/release.yml` are set; until then the build is ad-hoc signed.
