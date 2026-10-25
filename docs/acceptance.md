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
| 16 | Both shortcuts added and enabled via the setup page; origin change; local-PNG backup | | |

## Verified so far (development, not the presentation device)

- `npm test`: 23 server tests (API validation and fallback, 552 rules, run/ACK/resend, image-before-send, local-only and token boundary, languages, CSV import).
- `xcodebuild test` on the iOS 27 simulator: 31 Swift tests (store, processor order, dedupe, tsunami priority, Live Activity 4KB, languages, nationwide data, URLs).
- Simulator E2E: wss over a local test CA → bearer auth → hello → heartbeat → start-guide → ACK matched to the run (`notifications-denied`, because the simulator cannot grant notification permission from the CLI).
- Simulator: `Activity.request` succeeded. The Dynamic Island and lock-screen rendering were **not** visually confirmed.
- **Not verified**: lock-screen notification, wallpaper shortcut, LiveActivityIntent while locked, real Live Activity display. These need the physical iPhone.
