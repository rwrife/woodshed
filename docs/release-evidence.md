# Issue #8 — release evidence checklist

Status: **pre-release**. Updated 2026-10-05. Simulator validation is not a physical-device or TestFlight result. Do not mark a gate done without a linked run/build.

| Gate | Status | Evidence |
| --- | --- | --- |
| Exact Xcode 26.0.1 / 17A400 and iOS SDK 26.0 | Pending release run | `Scripts/select_xcode.py` fail-closed measurement in release workflow |
| Zero-network, semantic-color, iPhone-only source policy | Pending release run | Release workflow re-runs source gates |
| Signing certificate + provisioning profile | Pending Apple verification | Signed archive and `codesign --verify` must pass on macOS runner; certificate availability not inferred from secret names |
| Archived bundle `com.infinityball.woodshed`, `UIDeviceFamily == [1]`, build number | Pending signed archive | `Scripts/check_release_archive.py` reads archived app Info.plist, not the project source |
| Signed App Store export/IPA | Pending release run | Dispatch with upload=false to exercise archive, signing and export without submission |
| App Store Connect app record | Pending ASC API lookup | Release poller requires exactly one app for the bundle identifier |
| Processed TestFlight build | Pending upload-enabled run | Attach Actions run URL and ASC app/build ID with processing state VALID or COMPLETE |
| On-device install and TestFlight acceptance | Pending human/device verification | No device test or beta availability claim from simulator or upload alone |

## Execution order

1. Merge the release-workflow PR only after the pinned `ios` and Linux checks pass on its exact head.
2. Dispatch **Pinned iPhone release** on `main` with upload=false. Confirm the signing/archive validation and signed export steps each executed successfully (no skipped acceptance step). Record the run URL above.
3. Dispatch upload=true (or push a deliberate `v*` release tag on a verified commit), then wait for the poller's `PROCESSED_BUILD` line and record its actual app ID, build ID, state and run URL. A successful upload *without* processed build is not completion.
4. Keep issue #8 open if Apple signing limits, profile/record setup or processing blocks any step; report the exact failing step and run. Do not revoke team certificates or weaken the Xcode pin.

The four Actions secret **names** are `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`; their values are never stored in this repository or checklist. App Store submission is outside this milestone.
