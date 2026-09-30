# Issue #7 — Test + accessibility hardening pass: evidence & findings

Branch `feat/issue-7-hardening`. This document records what is automated,
what was found, and what is explicitly deferred to labeled follow-up
issues (no silent deferrals).

## What this PR automates

### 1. Derivation fuzz hardening (Linux package lane + macOS lane)

`Packages/WoodshedKit/Tests/WoodshedKitTests/DerivationFuzzTests.swift`
— fixed-seed (`20260929`) property tests over randomized ledgers × 7 time
zones (incl. 30/45-minute offsets: Asia/Kolkata, Pacific/Chatham,
Australia/Lord_Howe) × 4 DST-anchored windows (US/EU/southern-hemisphere
spring-forward and fall-back).

Invariants asserted against an **independent oracle** that walks a
different Foundation API path (`startOfDay` + whole-day component counting
instead of year/month/day extraction; day-walk week bounds instead of
`dateInterval(of: .weekOfYear:)`):

- `dayStreak` and `weeklyMinutes` concordance for every reference instant
  (session starts + deliberate ±hour/day near-misses) — including ledgers
  with same-id corrections (newest event must win).
- Week buckets partition the ledger exactly once (sum of per-week totals ==
  sum of per-session truncated minutes).
- Contract bounds: never 0-instead-of-nil, streak ≤ distinct practice days.
- Fixed-seed determinism (a CI failure is reproducible from the seed).

### 2. Contrast (semantic-color) gate — static, both CI lanes

`scripts/check_semantic_colors.sh`, wired into `ci.yml` (Linux lane) and
`Scripts/ci.sh` (macOS lane) as phase `semantic_color_gate`. App UI
sources must use system semantic colors/styles (which adapt to
Light/Dark and Increase Contrast) — literal `Color(...)`, `UIColor(...)`
construction is rejected, empty allowlist, mirroring the zero-network
gate policy. Current sources pass.

### 3. Simulator UI-test matrix (`UITests/AccessibilityHardeningUITests.swift`)

- **Wall empty state**: new `-ui-testing-empty-wall` launch flag starts the
  app with baseline records but no demo seed; asserts the empty-state copy
  renders, no cards exist, and Quick Start remains usable (readiness proven
  via the primary action, not the `ContentUnavailableView` id, which does
  not bridge into the AX tree).
- **Wall unknown state**: the merged wall-card accessibility element's
  label is VoiceOver's exact utterance — asserted in **read order**
  (title → status → last practiced → week → best tempo → vs target), all
  `Unknown` on an empty ledger, never silently zeroed.
- **Timer running / no focus trap**: elapsed readout exposes
  label=`Session elapsed time` + spoken duration value; two samples 2.2 s
  apart must differ (clock advances); Stop/Pause remain present and Stop
  stays hittable while the timer runs.
- **Dynamic Type AX5**: launch-argument override
  (`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`)
  proven applied **inside the app** via a flag-gated probe
  (`wall.sizeCategory`, gated on the abbreviated-rawValue spelling), then
  capture controls asserted ≥ 44 pt and scroll-reachable; full start →
  running → review flow at AX5. Screenshots ride inside `tests.xcresult`
  via `XCTAttachment(lifetime: .keepAlways)`.
- **Restore preview**: confirm/cancel announce their destructive/cancel
  roles by label.
- Existing matrix (capture, wall full/unknown, restore preview apply) stays
  in `SessionCaptureUITests`, `WoodshedLaunchTests`,
  `RestorePreviewUITests`.

VoiceOver narration order is asserted **via the AX contract**
(label/value strings XCUITest reports for merged elements). VoiceOver
itself is not XCUITest-scriptable; see follow-up below.

## Findings

1. **FIXED in-PR** — no unknown-state violations: derivations already
   return nil (never 0) across the fuzz sweep; wall copy keeps "Unknown".
2. **FIXED in-PR** — capture controls already carry ≥44 pt frames
   (`minHeight: 44–60` labels); now guarded by the AX5 test so a future
   regression fails CI.
3. **FILED as follow-up issue** — *Midnight-less DST days*: `Derivations.dayStreak`
   anchors a calendar day via `Calendar.date(from: dayComponents)`; in zones
   whose spring-forward skips local midnight (e.g. `America/Havana`,
   `America/Santiago`), the anchor day instant is non-existent and the
   streak correctly degrades to `nil` ("unknown") for references on such
   days. Conservative-but-imprecise; the fuzz time-zone set is restricted to
   zones that always have a midnight, with this note as the trail. Behavior
   change deferred past the hardening pass deliberately (RC risk).
4. **FILED as follow-up issue** — *manual VoiceOver + Increase Contrast
   walkthrough*: rotor navigation, hint phrasing, and contrast-appearance
   screenshots cannot be scripted from XCUITest; required pre-RC with the
   evidence format defined in the issue.

## Verification (this run)

- Linux lane (`swift:6.2-noble`, local Docker, mirrors CI): WoodshedKit
  `swift test` — 39 tests / 7 suites PASS (incl. 4 new fuzz suites).
- `scripts/check_zero_network.sh` PASS; `scripts/check_semantic_colors.sh`
  PASS; `bash -n Scripts/ci.sh` OK; `python3 -m unittest discover -s
  Scripts/tests` — 21 tests OK.
- macOS lane (pinned Xcode 26.0.1 / iOS 26.0 simulator + XCUITests + the
  new app-target files compile): **cannot execute on this Linux host** —
  pending the PR's `ios` CI job on the exact head SHA. No simulator result
  is claimed until that run is green.
