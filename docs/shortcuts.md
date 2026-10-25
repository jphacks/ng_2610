# Nigeyo shortcut and automation

One shortcut and one automation cover both earthquake and tsunami. Before each notification the server swaps the image behind the fixed URL `<origin>/public/assets/wallpaper.png` (earthquake or tsunami), so the iPhone side never changes.

`npm run shortcuts:build` generates and signs `assets/shortcuts/nigeyo-nigeyo.shortcut`. It is served from `GET /public/shortcuts/setup`.

| Item | Content |
| --- | --- |
| Shortcut **Nigeyo** | Get Contents of URL `<origin>/public/assets/wallpaper.png` → Set Wallpaper (lock screen, preview off) → open `nigeyo://guide` |
| Automation | Notification → App **Nigeyo** (no title filter; titles are `EARTHQUAKE_TEST` / `TSUNAMI_TEST`) → Run Shortcut **Nigeyo** |

- iOS cannot import or share personal automations, so the automation is the one manual step. The shortcut already opens the app at the end, so the automation needs only the single Run Shortcut action.
- The shortcut contains no token, key or personal bundle ID. The import question asks for the wallpaper URL; a new tunnel origin only means editing that one field.

## Setup on the iPhone

1. Allow Nigeyo notifications.
2. Open `https://<origin>/public/shortcuts/setup` (also linked from Settings → ショートカットを設定) and add **Nigeyo**. Replace `YOUR-TUNNEL.trycloudflare.com` with the tunnel host.
3. Shortcuts → Automation → **+** → Notification → App: Nigeyo. Choose **Run Immediately**, turn off **Notify When Run**, action **Run Shortcut → Nigeyo**.
4. Run the shortcut once by hand to grant the network and wallpaper permissions.
5. Lock the phone and start a demo from the Mac. Earthquake and tsunami demos can be started back to back; each new run replaces the previous session on the phone.

## Offline backup

Settings → ショートカットを設定 → **壁紙をFilesに保存** exports `earthquake.png` and `tsunami.png`. Make a copy of the shortcut and replace **Get Contents of URL** with **Get File**.

## Reset

Deleting app data does not remove the shortcut, the automation, the wallpaper or files in Files. Remove them in the Shortcuts app and pick your original lock screen.

## Unverified (device test required)

- The `Set Wallpaper` parameters (lock-screen target, preview off) must be checked on iOS 27. If they import wrongly, set them by hand.
- Whether the automation runs while the phone is locked, and whether opening the app needs an unlock. Record what the OS actually does.
