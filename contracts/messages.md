# WebSocket contract v2

Shared by `server/demo/runs.mjs` and `nigeyo-ios/Nigeyo/Contracts/Messages.swift`. UTF-8 JSON text frames, at most 16KB, `schemaVersion: 2`. Unknown `type` or invalid required values get an error reply, and no notification is scheduled. Spec reference: NIGEYO-TECH-SPEC.md §8.

| type | direction | sample |
| --- | --- | --- |
| `hello` | iPhone → Mac, on connect, after a language change and on returning to the foreground | [hello.sample.json](samples/hello.sample.json) |
| `heartbeat` | iPhone → Mac, every 5 s | [heartbeat.sample.json](samples/heartbeat.sample.json) |
| `start-guide` | Mac → iPhone | [start-guide.sample.json](samples/start-guide.sample.json) |
| `hazard-update` | Mac → iPhone, a tsunami for the **same** session | [hazard-update.sample.json](samples/hazard-update.sample.json) |
| `notification-ack` | iPhone → Mac | [ack-start.sample.json](samples/ack-start.sample.json), [ack-hazard.sample.json](samples/ack-hazard.sample.json) |
| `error` | Mac → iPhone, malformed device message | `{"schemaVersion":2,"type":"error","errorCode":"invalid-payload"}` |

## ACK addressing

- `start-guide` is acknowledged with `runId`. `hazard` is `"tsunami"` only when `scenario` is `"tsunami"` (the session starts in the tsunami guide); otherwise `"earthquake"`.
- `hazard-update` is acknowledged with `commandId`, `sessionId` (the original runId), `hazardRevision` and the device's `stateRevision` after saving.
- `status`: `scheduled` | `duplicate` | `rejected` | `failed`. `rejected` and `failed` always carry an `errorCode`:
  `unsupported-version`, `invalid-payload`, `expired-command`, `clock-skew`, `notifications-denied`, `storage-failed`, `notification-failed`, `session-busy`, `language-mismatch`, `language-package-missing`, `stale-revision`.
- `scheduled` means the OS accepted the local notification request. It does **not** prove the screen lit up or the wallpaper changed.

## Timing

- `expiresAt = sentAt + 20 s`. The device rejects expired commands (`expired-command`) and commands whose `sentAt` is ≥5 s in its future (`clock-skew`). This is separate from the quake's own (often old) `issuedAt`.
- No ACK after 5 s: the server resends **once** with the same id. No ACK after another 5 s: `ack-unknown`, shown as "予約成否不明". A late success ACK upgrades it to `scheduled`. The server never retries with a new runId.

## Tsunami

- `hazard-update.source = "local"` is a synthetic drill: `tsunami` is `null`, with no fabricated `sourceEventId`.
- Any other source carries a TsunamiSummary `{sourceEventId, code: 552, issuedAt, cancelled, area, grade}` limited to the configured target area.
- Ordering uses `hazardRevision`, a monotonic per-session counter on the server. `stateRevision` is assigned only by the device's SessionStore.

Related files: [language-package.schema.json](language-package.schema.json) and [required-string-keys.json](required-string-keys.json) (generated from the packages; every language must match the keys and typed placeholders).
