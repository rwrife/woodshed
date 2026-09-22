# Issue #1 bootstrap evidence

Dated record of what was actually verified, where, and what remains CI-only.

## What this bootstrap adds

- `Woodshed.xcodeproj` with shared `Woodshed` scheme (app + UI-test targets),
  bundle id `com.infinityball.woodshed`, `TARGETED_DEVICE_FAMILY = 1` in every
  build configuration, iOS 26.0 deployment target, Swift 6 language mode.
- `App/`: SwiftUI launch-only placeholder (`WoodshedApp` + `BootstrapHomeView`)
  wired to `Packages/WoodshedKit`.
- `Packages/WoodshedKit`: pure Swift 6 package (Foundation only) with
  swift-testing placeholder tests proving the Linux lane works.
- `UITests/WoodshedLaunchTests.swift`: simulator launch smoke test asserting
  the `bootstrap.home` accessibility identifier and home-screen copy.
- `Scripts/`: pinned toolchain selection (measured version/build/SDK match),
  simulator selection/boot helpers with bounded subprocess timeouts and a
  bounded one-shot retry for known hosted-runner boot/enumeration wedges, and
  the CI entrypoint `Scripts/ci.sh` (phase-tracked provenance on every exit).
- `scripts/check_zero_network.sh`: empty-allowlist scan of `App/`, `UITests/`,
  and `Packages/*/Sources/` for network APIs (`.build` dirs excluded).
- `.github/workflows/ci.yml`: Linux package job (`swift:6.2-noble`) plus a
  macOS job with exact-head checkout, pinned-toolchain validation, and
  always-upload artifacts.

## Toolchain enforcement

`toolchain.json` pins Xcode 26.0.1 (17A400) / iPhoneOS SDK 26.0 / Swift 6 mode /
deployment target 26.0, exactly as the README and PLAN require. `Scripts/select_xcode.py`
measures `xcodebuild -version` and `xcrun --sdk iphoneos --show-sdk-version` for every
installation under `/Applications` and only accepts an actual version/build/SDK match;
a missing pin is a hard CI failure (`PinError`), never a silent fallback. The workflow
checks out `github.event.pull_request.head.sha` explicitly, so CI tests the exact PR
head commit, not a synthetic merge ref.

## iPhone-only and zero-network enforcement

`Scripts/ci.sh` enforces iPhone-only policy twice: an `iphone_only_pregrep` phase
fails before compiling unless every `TARGETED_DEVICE_FAMILY` setting in
`Woodshed.xcodeproj` is exactly `1` (any `1,2` or `2` fails), and after the build the
`device_family_guard` phase converts the built `Woodshed.app/Info.plist` to JSON and
fails unless `UIDeviceFamily == [1]`; the JSON is uploaded as `app-info.json`.

The zero-network gate scans app sources, UI tests, and package sources against an
explicit EMPTY allowlist; any match on URLSession/Network.framework/CFNetwork/POSIX
socket vocabulary fails the run. A signing-material gitignore probe asserts `*.p8`,
`*.p12`, `*.mobileprovision`, and `*.cer` cannot be committed.

All simulator subprocesses are bounded (30 s enumeration, 120 s boot, 180 s
bootstatus) with logs preserved in `build/ci-artifacts`, and the workflow uploads
artifacts with `if: always()` so failures keep their provenance
(`provenance.txt` records expected/actual SHA, phase, and exit status).

## Verification actually performed (Linux executor, no Swift/Xcode on host)

- `python3 -m unittest discover -s Scripts/tests` — helper tests for bounded
  boot/timeout/exit-code behavior, simulator selection, and exact Xcode pin
  selection all pass locally.
- `swift test` for `Packages/WoodshedKit` executed for real inside Docker
  (`swift:6.2-noble`), matching the CI Linux job image exactly.
- `bash -n Scripts/ci.sh` and `bash -n scripts/check_zero_network.sh` — syntax OK.
- `scripts/check_zero_network.sh` run against the ported tree — PASS.
- pbxproj object-ID closure probe (defined == referenced, all 24-hex) — clean.
- Workflow YAML and `toolchain.json` parse; `git diff --check` clean.
- grep: `TARGETED_DEVICE_FAMILY = 1;` present in all four target configurations,
  zero iPad variants, bundle id `com.infinityball.woodshed` in both app configs.

## CI-pending claims (NOT claimed from this host)

- The macOS Xcode/SDK pin measurement, simulator build, launch XCUITest, embedded
  `Info.plist` `UIDeviceFamily == [1]` check, and built-app bundle-id check are
  **CI-pending**: the authoritative evidence is the macOS CI run for this PR's
  exact head SHA, retained in the `ios-ci-<sha>` artifact. Results are recorded
  on the PR when they exist, never pre-declared.

## Explicit non-claims

- No physical-device, VoiceOver, or signed-archive evidence exists or is claimed.
- No TestFlight/upload path exists (issue #8 owns that).
- The simulator test proves launch + home-screen rendering only; product journeys
  arrive with issues #2–#5.
- Hosted `simctl` startup has known transient hangs; a red CI run at a proven
  unchanged tree is retried once before being reported as an environment blocker.
