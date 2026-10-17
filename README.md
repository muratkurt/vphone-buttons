# VPhone Buttons

The iPhone's hardware buttons for [vphone-cli](https://github.com/Lakr233/vphone-cli) virtual iPhones, in a small Mac app: Action Button, Camera Control, volume, Home and screenshots.

An independent companion app; not part of vphone-cli.

## Buttons

- **Action Button** — press, double press, long press
- **Camera Control** — click, double click, press and hold, light press (and hold), slide up / down, menu, menu slide, touch, swipe
- **System** — volume up / down, play / pause, Home, screenshot (saved to a folder you choose)

12 languages.

## Requirements

- Apple silicon Mac, macOS 14 or later
- Running vphone-cli machines. The app talks to each machine's `vphone.sock` under `~/.vphone/machines` (change it in Settings).
- Camera Control only: a jailbroken guest on iOS 26 or later (RootHide or rootless) with **ccevent** installed — a virtual iPhone has no Camera Control sensor, ccevent sends its events inside the guest.

## Install

1. Download `VPhone-Buttons.zip` from [Releases](../../releases), unzip, move the app to Applications. It is not notarized: if macOS blocks it, allow it in System Settings › Privacy & Security.
2. For Camera Control, install `ccevent-1.0.0-roothide.deb` or `ccevent-1.0.0-rootless.deb` in the guest (Sileo, Filza or `dpkg -i`).

## Build

```sh
./build.sh                                   # build/VPhone Buttons.app, build/VPhone-Buttons.zip
cd ccevent && make package THEOS_PACKAGE_SCHEME=roothide   # or rootless (Theos)
python3 tools/strings.py                     # after editing the strings table
```

## How it works

Buttons go through the machine's control socket (`input.button`, HID usages). For Camera Control, ccevent builds the `TouchSensitiveButton` and `ForceStage` HID events in the guest; the app runs it as a one-shot launchd job, so a whole gesture keeps the button's timing.

## Bugs

Open an [issue](../../issues/new) with your macOS, vphone-cli and guest iOS versions.

## Credits

Built with [Claude Code](https://claude.com/claude-code).

## Licence

[MIT](LICENSE).
