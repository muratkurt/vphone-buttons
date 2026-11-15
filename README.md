# VPhone Buttons

The iPhone's hardware buttons for [vphone-cli](https://github.com/Lakr233/vphone-cli) virtual iPhones, in a small Mac app: Action Button, Camera Control, side button, volume, Home and screenshots. It also installs apps (.ipa, .tipa, .app) into a running machine.

An independent companion app; not part of vphone-cli.

## Buttons

- **Action Button** — press, double press, long press
- **Camera Control** — click, double click, press and hold, light press (and hold), slide up / down, menu, menu slide, touch, swipe
- **System** — volume up / down, play / pause, Home, App Switcher, side button (lock / wake), Siri, unlock, screenshot (saved to a folder you choose)

## Installing apps

Choose an `.ipa`, `.tipa` or `.app` (or drop it on the window), pick how it goes in, and press Install.

| Install as | What happens |
|---|---|
| Automatic | `.tipa` → TrollStore, anything else → App |
| App | A normal app in its own container (sandboxed) |
| TrollStore | Unsandboxed, with the entitlements the app declares |
| Jailbreak | Into the jailbreak's `Applications` folder (RootHide or rootless) and registered as a system app; `SBAppUsesLocalNotifications` is added so notification permission sticks |

- **Signing** — the app is signed ad hoc on the Mac, keeping the entitlements it has; nested frameworks, dylibs and extensions keep theirs. `embedded.mobileprovision` is dropped. Unsigned Xcode builds work as they are.
- **Keychain access** — adds `application-identifier` and a keychain access group when the app has none, so an unsigned build can use the keychain.
- **Preferences** — `key=value` lines are written to the app's preferences before it starts (`true` / `false` → boolean, whole numbers → integer, the rest strings). cfprefsd is restarted first, so the app reads the new values.
- **Open after install / Screenshot** — launches the app (unlocking a guest without a passcode if needed) and saves a screenshot.
- Installing the same bundle ID the other way (App ↔ Jailbreak) removes the earlier install first.

12 languages.

## Requirements

- Apple silicon Mac, macOS 14 or later
- Running vphone-cli machines. The app talks to each machine's `vphone.sock` under `~/.vphone/machines` (change it in Settings).
- Installing apps: vphone-cli 2.9 or later (its guest daemon provides `apps.install` and `apps.register`); Jailbreak install needs a jailbroken guest.
- Camera Control only: a jailbroken guest on iOS 26 or later (RootHide or rootless) with **ccevent** installed — a virtual iPhone has no Camera Control sensor, ccevent sends its events inside the guest.

## Install

1. Download `VPhone-Buttons.zip` from [Releases](../../releases), unzip, move the app to Applications. It is not notarized: if macOS blocks it, allow it in System Settings › Privacy & Security.
2. For Camera Control, install `ccevent-1.0.0-roothide.deb` or `ccevent-1.0.0-rootless.deb` in the guest (Sileo, Filza or `dpkg -i`).

## Build

```sh
./build.sh                                   # build/VPhone Buttons.app, build/VPhone-Buttons.zip (needs Xcode for the iOS helper)
cd ccevent && make package THEOS_PACKAGE_SCHEME=roothide   # or rootless (Theos)
python3 tools/strings.py                     # after editing the strings table
```

## How it works

Buttons go through the machine's control socket (`input.button`, HID usages). For Camera Control, ccevent builds the `TouchSensitiveButton` and `ForceStage` HID events in the guest; the app runs it as a one-shot launchd job, so a whole gesture keeps the button's timing.

Installing uses the same socket. A request carries at most about 512 KB and cannot append to a file, so a package goes up in parts and `vpbhelper` (a small iOS helper inside the app, see `helper/`) joins them in the guest, again as a one-shot launchd job; then `apps.install` (App, TrollStore) or `apps.register` (Jailbreak) does the rest.

## Bugs

Open an [issue](../../issues/new) with your macOS, vphone-cli and guest iOS versions.

## Credits

Built with [Claude Code](https://claude.com/claude-code).

## Licence

[MIT](LICENSE).
