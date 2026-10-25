# Device acceptance record (spec §20.2)

Fill this in on the presentation Mac, iPhone, signing setup and shortcuts. Only record what you observed. ActivityKit success and on-screen display are recorded separately.

Device / iOS: ______ · App bundle ID: ______ · Xcode attached: yes / no · Date: ______

| # | Check | Result | Notes (tap count, OS prompts, times) |
| --- | --- | --- | --- |
| 1 | Onboarding saves the 4 slots, or "no candidate" | | |
| 2 | Heartbeat shown 15 s, 1 min, 3 min after locking | | |
| 3 | Live API → locked notification → earthquake wallpaper → unlock → same protect screen → Live Activity on the next lock | | |
| 4 | Image visible before touching the phone; no audio guidance; Live Activity confirm shows the 3 checks plus 安全でないと感じたら | | |
| 5 | Forced API failure: last-good, then fixture; the operator source is correct | | |
| 6 | Resending the same runId gives no double notification and no reset | | |
| 7 | Same quake with 3 different runIds: each ends and restarts | | |
| 8 | en / ja / ko consistent across app, notification and Live Activity; a 4th JSON language appears without code changes | | |
| 9 | In-app drill makes no API call and notifies after locking | | |
| 10 | Tsunami updates wallpaper, Live Activity and state without the confirm tap; a cancelled 552 never starts evacuation; no earthquake-only sites shown | | |
| 11 | Google Maps link works with and without the Google Maps app; there is no in-app navigation | | |
| 12 | Offline: bundled text, saved sites and the nationwide distance search work | | |
| 13 | Normal launch without Xcode, recorded separately | | |
| 14 | Live Activity → 安全でないと感じたら → (auth) → home / school / other → going ends the Activity | | |
| 15 | Live Activity off; tsunami before an Activity exists; dismissed Activity; tsunami vs confirm race; redraw after end | | |
| 16 | Two image-embedded shortcuts added; title-filtered native triggers included and enabled after import; old catch-all disabled; no network at shortcut execution; origin change | | |

## Verified so far (development, not the presentation device)

- `npm test`: 23 server tests (API validation and fallback, 552 rules, run/ACK/resend, image-before-send, local-only and token boundary, languages, CSV import).
- `xcodebuild test` on the iOS 27 simulator: 31 Swift tests (store, processor order, dedupe, tsunami priority, Live Activity 4KB, languages, nationwide data, URLs).
- Simulator E2E: wss over a local test CA → bearer auth → hello → heartbeat → start-guide → ACK matched to the run (`notifications-denied`, because the simulator cannot grant notification permission from the CLI).
- Simulator: `Activity.request` succeeded. The Dynamic Island and lock-screen rendering were **not** visually confirmed.
- **Not verified**: lock-screen notification, wallpaper shortcut, LiveActivityIntent while locked, real Live Activity display. These need the physical iPhone.

## Local-wallpaper / multiple-phone change (2026-10-25)

New physical-device checks (pending; do not infer success from automated tests):

- Install both signed shortcuts: each contains its correct approved PNG. No URL or Files selection is required.
- Run each in airplane mode: earthquake has peach background, tsunami has blue background.
- EARTHQUAKE_TEST runs only Nigeyo 地震; TSUNAMI_TEST runs only Nigeyo 津波. Disable the old unfiltered automation.
- Connect two phones (Nagoya/Tokyo), select each in the operator UI, send different hazards simultaneously, and check each wallpaper and guide.
- Reconnect one phone: select its new connection id. An old id never targets another phone.
- Check locked execution, permissions, app opening after authentication and consecutive hazard notifications on both phones.

Backend regression tests exercise two actual WebSocket clients, different concurrent scenarios/languages, cross-device ACK rejection, independent tsunami updates and reset, immutable images, and offline shortcut contents. These do not prove iOS action imports or on-device automation execution.

## Bundled notification triggers (2026-10-25)

- Verify import shows the notification trigger and EARTHQUAKE_TEST / TSUNAMI_TEST title-contains filter without manually creating a separate automation.
- Enable each imported automation, check the Nigeyo app binding (especially development bundle ID suffixes), and allow locked execution as needed.
- The trigger serialization was obtained from an actual macOS 27 Shortcuts UI export; the exported local app picker identity and personal Team ID are not distributed.
- Both final archives were Apple-signed and inspected: title filters, target bundle ID, embedded PNG bytes and guide URL match the source. All 30 Node tests and demo preflight pass.
- The macOS import preview recognizes the earthquake notification trigger and title-contains condition. On this Mac the distribution bundle ID did not resolve and the preview showed Pages. Both recipients must reselect their installed Nigeyo app before enabling; correct iPhone app resolution is not yet verified.
- Physical iPhone notification delivery and post-import enablement remain device acceptance checks.

## App-bundled shortcut onboarding (2026-10-25)

- Based on main at `7896658`, branch `feat/bundled-shortcut-onboarding`.
- Both signed shortcuts are bundled in the iOS app; copied bytes match the distribution hashes. No public URL or pairing is used by the setup UI.
- Four guided steps replace the previous instruction list and nested web setup page. The single completion action at each stage is an explicit user confirmation; opening a file never marks it installed. Progress persists without completing onboarding.
- `npm test`: 41 tests passed. `xcodebuild test` on iPhone 17 / iOS 27.0 simulator: 36 Swift tests passed, including bundled-file export/name consistency and partial-progress persistence/reset.
- Physical-device import via the system document handoff (including Save to Files fallback), Shortcuts automation enablement, wallpaper changes and locked notification execution remain pending. Simulator GUI interaction was unavailable through the current automation interface; no visual walkthrough is claimed.

## Confirmation after wallpaper change (2026-10-25)

- Shortcut v1.5.1 changes the lock-screen wallpaper before showing a cancellable alert; OK continues to `nigeyo://guide`.
- The initial `is.workflow.actions.showalert` identifier appeared as an unknown action on the iPhone. Corrected it to `is.workflow.actions.alert`, rebuilt and signed both files, and installed the updated app on the connected iPhone 16.
- The user confirmed that the corrected version worked on the physical iPhone and approved merging. Separate results for both hazards, locked notification execution, and each OK/Cancel path were not individually reported.
- The six shortcut regression tests passed, including inspection of the actual signed files and matching app-bundled bytes. The device Debug build succeeded.

## Wallpaper-only shortcuts (2026-10-25)

- v1.6.0 ends immediately after setting the lock-screen wallpaper. The confirmation alert and `nigeyo://guide` action were removed from both hazards.
- Setup descriptions in Japanese, English and Korean now describe wallpaper changes only. Existing users must replace both installed shortcuts with the new files.
- Both files were rebuilt and Apple-signed, then copied into the app. `node --test test/local-shortcuts.test.mjs`: all 6 tests passed, including inspection of the signed workflows ending at Set Wallpaper and matching distribution/app hashes.
- Physical-device execution of this version remains pending. Earlier confirmation-flow results above refer to the previous version.

## Bounded demo connection after locking (2026-10-25)

- When a connected demo becomes inactive, the app requests a UIKit background task. Inactive → background shares one lease; foreground return, explicit disconnect, data deletion, system expiration, or the 25-second cap releases it.
- iOS controls the actual time granted. Neither 20 nor 25 seconds of locked WebSocket delivery is guaranteed. This remains a demo transport, not a background push channel.
- After a background transition, foreground return reconnects the saved pairing if auto-connect is enabled, replacing a socket that may still appear connected after suspension. Explicit disconnect keeps auto-connect off.
- In-app training already reserves local notifications before locking. For dependable locked demonstrations, start in-app training while foregrounded and then lock. Server-triggered commands still require a live connection when received; once acknowledged as scheduled, their local notification does not require the socket to remain open.
- Physical-device acceptance: connect, lock, trigger from the PC within 5/15/20 seconds and inspect the ACK/notification; repeat beyond 25 seconds to observe the limit; unlock and verify reconnect; manually disconnect and lock/unlock to confirm no automatic reconnection. Repeat without an Xcode debugger, which can affect suspension. Actual locked duration and notification delivery remain unverified until these device checks pass.
- Validation: iOS simulator build succeeded; 41 of 42 tests passed, including all five new background-grace tests (shared lease, release, expiration, stale expiration, and duration cap). The remaining BundledShortcutsTests export test fails with Cocoa error 516 (existing filename); the identical failure was reproduced on unmodified main `7d263bc`. All 41 Node tests passed. No physical iPhone test or deployment was performed for this change.
- Physical-device follow-up: built and installed exact revision `9e6d229` on the connected iPhone 16 and launched it without an attached Xcode debugger. A matching demo server and HTTPS tunnel were prepared. The user confirmed the improvement and approved merging to main. Individual 5/15/20-second timings and expiration behavior were not separately reported.
