# Woodshed — PLAN

## Scope

A local-first, iPhone-only, native-Swift practice-log app for musicians. MVP = ledger capture (sessions with per-piece splits and user-entered achieved tempos) + deterministic derivations (streaks, weekly minutes, per-piece recency/tempo progress) + practice-wall UI + user-owned backup/export. Zero network. See README for the full feature list and non-goals.

## Architecture

```
┌──────────────────────────────────────────────┐
│ Woodshed app (SwiftUI, iPhone-only)          │
│  SessionCapture · PracticeWall · PieceDetail │
│  PracticeWorkspaceLayout  ← dual-screen seam │
├──────────────────────────────────────────────┤
│ WoodshedStore (GRDB/SQLite, migrations)      │
├──────────────────────────────────────────────┤
│ WoodshedKit (pure Swift 6, no UI, no I/O)    │
│  Ledger model · Derivations · Backup codec   │
└──────────────────────────────────────────────┘
```

- **`WoodshedKit`** — a Swift Package with zero dependencies beyond Foundation:
  - Domain types: `Instrument`, `Piece` (status: active/maintenance/retired), `Session`, `SessionSplit`, `TempoLog` (user-entered integer BPM), `PracticeNote`.
  - **Append-only event ledger**: sessions and splits are immutable once committed; edits are new corrected events. Derived views never mutate history.
  - **Derivations** are pure functions: day-streak and current-streak over calendar dates (local timezone, DST-safe via `Calendar.current` date components), weekly minutes over calendar weeks, days-since-last, per-piece totals, best/last logged tempo, delta-to-target. Unknown (no data) renders `unknown` — never zero and never "safe/normal" language.
  - **Backup codec**: versioned JSON (`schema_version` integer), lossless round-trip, forward-incompatibility rejected with a clear error.
- **`WoodshedStore`** — GRDB-backed persistence, `DatabaseMigrator` with versioned migrations, repository protocols matching sibling-repo conventions (`PieceRepository`, `SessionRepository`, …) with in-memory fakes for tests.
- **App target** — SwiftUI views; `AVFoundation` is *not* used (no audio features). `PracticeWorkspaceLayout` centralizes every layout decision that a future dual-screen API would touch; today it maps size classes to single-column/compact layouts.

## Technology choices (rationale)

| Choice | Rationale |
|---|---|
| Swift 6, SwiftUI | User directive: native Swift only; strict concurrency from day one. |
| iOS 26 SDK, deployment target 26.0 | Project policy: iOS 26+ pinned in `toolchain.json`; CI measures exact Xcode 26.0.1 (17A400). |
| GRDB/SQLite | Proven in sibling labs (carelabel, gift-vault, rise-log): versioned migrations, testable on Linux, query-friendly. |
| Pure `WoodshedKit` package | Derivations testable on Linux CI (no Xcode needed), fast table-driven tests. |
| No networking | Privacy claim is structural, enforced by a CI zero-network gate (empty import allowlist). |
| Xcodeproj generated/pinned via CI pattern of sibling repos | Reproducible skeleton on Apple CI without committing a hand-tuned project. |

## Milestones & dependency order

1. **M0 Skeleton** (issue #1) — Xcode project + `WoodshedKit` package + CI: exact-toolchain assertion, iPhone-only guard (`TARGETED_DEVICE_FAMILY=1`, built `UIDeviceFamily == [1]`), zero-network gate, launch smoke test. Depends on: nothing.
2. **M1 Domain** (#2) — ledger model, derivation engine, backup codec with exhaustive table tests. Depends on M0 (package target).
3. **M2 Store** (#3) — GRDB schema v1, migrator + committed fixture DB, repositories + fakes. Depends on M1.
4. **M3 Capture UI** (#4) — start/stop/switch/pause/undo session flow writing through repositories. Depends on M2.
5. **M4 Wall & detail UI** (#5) — practice wall, piece detail, `PracticeWorkspaceLayout` seam + continuity contract documented. Depends on M2, M3.
6. **M5 Backup/export** (#6) — Files-app JSON backup/restore (previewed replace), CSV export. Depends on M1 codec, M2 store.
7. **M6 Test & accessibility pass** (#7) — unit + snapshot-free UI tests, VoiceOver labels, Dynamic Type audit. Depends on M3–M5.
8. **M7 Release packaging** (#8) — signed TestFlight upload via ASC API secrets, release checklist gated on *real* processed-build evidence. Depends on M6.

## Testing strategy

- **Linux CI**: `swift test` on `WoodshedKit` (pure Foundation) — derivations, streak/DST edge cases, tempo arithmetic, backup round-trip, fuzz-style ledger invariants. GRDB store tests where the SQLite-linked package tests run on Linux (sibling-verified pattern).
- **macOS CI (pinned Xcode)**: full app build + simulator unit/UI tests, iPhone-only post-build check, zero-network grep gate, exact toolchain measurement.
- **Device/TestFlight**: only claimed when a real processed build exists in App Store Connect; never inferred from simulator success.

## Packaging / distribution

Ad Hoc → TestFlight via App Store Connect API (secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` — names only). Bundle ID `com.infinityball.woodshed` (registered). App Store submission is a post-MVP step requiring user go-ahead; every release claim requires real evidence.

## Risks

- **Exact-pin toolchain absence on runners** → treat as environment blocker; rerun on fresh runner, never substitute a different Xcode silently.
- **Streak/week math across DST & time zones** → pure functions take `Calendar` explicitly; table-driven tests include DST-transition days; unknown-safe.
- **Timer fidelity during backgrounding** → wall-clock-anchored splits (persist start timestamp; compute elapsed on resume) rather than counting ticks.
- **GRDB on Linux CI** → follows sibling-repo recipe (swift:6.x + libsqlite3-dev); fallback is store tests macOS-only with disclosure.

## Explicit non-goals

No audio features (tuner/metronome/recording), no MIDI/score storage/OCR, no accounts/cloud/social, no teacher dashboard, no AI practice plans, no health/medical claims, no Android, no native iPad support (opt-in only), no monetization. The dual-screen experience is a documented design target with a single seam (`PracticeWorkspaceLayout`), not a current API dependency.
