# Woodshed

**Woodshed is a local-first iPhone practice log for musicians: start a session with one thumb, track minutes and tempo per piece, and glance at a practice wall of everything you're working on — no accounts, no cloud.**

Public repo: https://github.com/rwrife/woodshed

## Overview

Most practice problems aren't motivation — they're memory. You sat down for 25 minutes, but *what* did you actually work on, how long on each piece, was the Etude faster than last Tuesday, and how many days has it been since you touched the second Bach invention? Woodshed makes those questions answerable with a one-tap session timer and a per-piece ledger, then derives honest status (streaks, weekly minutes, tempo progress) from what you actually logged.

The core objects are:

- **Piece** — something you practice: a tune, study, etude, set list, scale routine, audition excerpt. Owned by an instrument. Carries optional user-entered target tempo and status (active / maintenance / retired).
- **Session** — a dated practice visit with a wall-clock duration and zero or more per-piece time splits, optional achieved tempos (user-entered BPM), and short notes.
- **Derived status** — pure functions over the ledger: days-since-last, current/day-streak, rolling weekly minutes, per-piece minutes and best logged tempo. Unknown inputs render *unknown*, never a guess.

## Motivation

Practice-tracking apps tend to be either (a) a bare stopwatch that records one number per day, hiding where the time actually went, or (b) a heavyweight lesson platform with teacher dashboards, cloud accounts, and subscription walls. Musicians mid-session don't want to type; they want to tap "start," switch pieces with a thumb, and get on with playing. Instructors and students alike want per-piece accountability, not just "I practiced today." And tempo progress — the single most motivating number in technique work — is almost never persisted anywhere.

Woodshed keeps the capture friction near zero and moves all the thinking into deterministic, offline derivation.

## Target users

- Self-directed adult learners and returning players who practice alone and forget what they did.
- Students with weekly lessons who want to show (and see) real per-piece work between lessons.
- Multi-instrument players who need separate walls per instrument.
- Anyone who wants practice streaks without a social feed or an account.

## Concrete use cases

1. **25-minute evening session.** Tap *Start*, pick "Etude Op. 10 No. 3," switch to "Scales" with one thumb mid-session, stop. Minutes auto-split per piece; optionally log the metronome marking you actually hit.
2. **Lesson prep.** Open a piece, see minutes since last lesson and your last five logged tempos — walk into the lesson with evidence.
3. **Practice wall.** Glance view of every active piece: last practiced, minutes this week, tempo progress. Cold pieces are visibly cold.
4. **Honest audit.** "Did I really practice 5 days last week?" The streak and weekly-minutes tiles are computed from the ledger, and the ledger is inspectable and exportable.

## How to use (intended workflow)

1. Create your instrument(s) and pieces once (name, optional target tempo, optional notes).
2. Tap *Start session* — the timer runs; switch the active piece (or free time) as you work.
3. When you stop, confirm the auto-split minutes and optionally add achieved tempo(s) + a one-line note.
4. Check the wall between sessions; review a piece's history before a lesson or performance.
5. Back up anytime from Settings (JSON via Files), export a CSV of sessions, and restore from a backup with a previewed replace.

## MVP features

- Instruments and pieces with user-entered target tempo (integer BPM) and status machine: active → maintenance → retired (retained in history).
- Session timer with per-piece split switching, pause, undo; wall-clock-anchored splits.
- Per-session notes and per-piece achieved-tempo log entries (user-entered integers only).
- Derived tiles: day streak, weekly minutes (calendar-week, local-timezone, DST-safe), per-piece days-since-last, minutes totals, best logged tempo, tempo delta vs target.
- Practice wall (per instrument) + piece detail with history.
- Local GRDB/SQLite store, versioned migrations; JSON backup/restore via Files with previewed replace; CSV session export.
- VoiceOver-friendly; large one-handed controls; Dynamic Type.

## Non-goals

- No tuner, metronome, drone, or any audio generation — the OS and your real metronome do that.
- No audio recording, no MIDI, no score/PDF storage or OCR.
- No teacher/student accounts, no cloud sync, no social feed, no sharing.
- No music-theory instruction, no practice-plan AI, no "tips" engine.
- No regulation of what counts as "enough" practice — no goals enforcement, no health claims. Minutes are minutes; the app never asserts benefit.
- No Android version, no native iPad app (see Platform scope).

## iPhone Duo (dual-screen) design target

Woodshed is designed as a **future iPhone Duo citizen** while being built today as a standard iPhone app:

- **Folded / today:** one-handed Quick Start + running-timer bar; wall is a glance list.
- **Unfolded target:** wall as a persistent left control surface while the right side shows the session workbench (live splits, tempo logging) — the classic console/detail span — and continuity of selection/timer across fold transitions.
- **Migration path:** all layout decisions funnel through a single `PracticeWorkspaceLayout` seam. When Apple ships dual-screen/fold APIs, only that seam gains real fold-region awareness. Until then the app uses standard SwiftUI size classes on iPhone; **no dependency on unavailable fold APIs exists or is introduced.**

## Platform scope

- **Native Swift (SwiftUI/UIKit) only** — Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity and other cross-platform/hybrid frameworks are prohibited by project policy.
- **iPhone-only on iOS.** `TARGETED_DEVICE_FAMILY = 1` in every app-target build configuration; native iPad support is **disabled** and requires explicit user opt-in. Android is out of scope entirely.
- **iOS 26 SDK or newer**, pinned in [`toolchain.json`](toolchain.json) (Xcode 26.0.1 / build 17A400 / iOS SDK 26.0, Swift 6 mode). CI asserts the exact measured toolchain; a missing exact pin is an environment blocker, never a silent substitute.
- Bundle identifier: `com.infinityball.woodshed` (registered in App Store Connect: `CREATED com.infinityball.woodshed`).
- Release path: Ad Hoc/TestFlight builds via App Store Connect API using the repository Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` (names only — values live exclusively in the secret store).

## Privacy, permissions, and data storage

- **Zero network.** No networking code ships in the MVP; a CI gate fails the build on new network imports. No accounts, no analytics, no ads, no crash reporting beyond Xcode defaults.
- Data lives in a local SQLite (GRDB) store in the app container. Photos of sheet music, microphones, location, contacts, and HealthKit are **not used and not requested** — the app needs **no permission prompts at all**.
- Backups are user-initiated JSON via the Files app; CSV exports are user-initiated and previewed. Nothing leaves the device unless the user exports it.
- Deleting the app deletes all data. Restore always previews before replacing.

## Current status & milestones

Documentation/backlog stage: **no Xcode project, application build, test suite, device behavior, archive, or TestFlight binary exists yet.** The backlog implements, in order:

1. Project skeleton + CI (iPhone-only + zero-network gates)
2. `WoodshedKit` pure domain (ledger, derivations, unknown-safe semantics)
3. GRDB store + migrations + repositories
4. Session-capture workflow UI
5. Practice wall + piece detail UI (incl. `PracticeWorkspaceLayout` seam)
6. Backup/export/restore + privacy controls
7. Test + accessibility pass
8. TestFlight/release packaging with real evidence gates

## Development quickstart

This repository currently holds documentation and backlog only. When the skeleton lands (issue #1):

```bash
# Requires an Apple environment with the pinned toolchain (see toolchain.json).
xcodebuild -project Woodshed.xcodeproj -scheme Woodshed \
  -sdk iphoneos -destination 'generic/platform=iOS' build
xcodebuild -project Woodshed.xcodeproj -scheme WoodshedKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

On non-Apple hosts, the pure-domain package builds and tests under any Swift 6 toolchain (e.g. `swift test` in the package directory); app-target work requires macOS CI with the pinned Xcode.

## License

MIT — see [LICENSE](LICENSE).
