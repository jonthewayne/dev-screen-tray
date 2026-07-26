# Dev Screen

A tiny macOS **menu-bar app** to remote into another Mac's screen (macOS Screen Sharing) in one click,
over **Tailscale** — from anywhere, not just the same Wi-Fi. Plus the physical-display controls
(black out / restore / lock) for driving a headless dev box unseen. Companion to
[ServeSim Tray](../serve-sim-tray).

## What you get

- Menu-bar icon (a display glyph) with a live **reachable / unreachable** status.
- **Connect (Screen Share)** blacks out the dev Mac and keeps its physical brightness at zero during the session.
- **Black Out Screen** / **Restore Brightness** / **Lock Dev Mac**.
- **Start at Login**, in-app **Guide**.

During a screen-sharing session, **Restore Brightness** pauses blackout enforcement and **Black Out
Screen** resumes it. **Stop Screen Share** stops the monitor immediately, then blacks and sleeps the
dev Mac's display. No brightness polling runs while disconnected.

## Requirements

| Need | Why |
|---|---|
| Two Macs on **Tailscale** | reachable from anywhere |
| **Screen Sharing** on the dev Mac | the remote desktop |
| **SSH key** authorized on the dev Mac | brightness + lock commands |
| **`brightness`** CLI on the dev Mac | Black Out / Restore (true 0 brightness) |

## Configure

No editing needed — the first time you hit **Connect** (or open **Settings ▸ Dev Machine**), the app
lists the Macs on your **Tailscale network**, you pick one and enter its **login username** (no password:
SSH uses your key, macOS handles the screen-share login). It's saved to `~/.config/dev-screen/config`,
which `dev-screen-ctl` reads:
```zsh
DEV_USER=starborn
DEV_IP=100.120.153.119
DEV_HOST=mighteous
```

## Build

```bash
./build.sh install    # compiles + copies "Dev Screen.app" to /Applications, then launches it
```

Then turn on **Start at Login** (Settings). (`./build.sh` alone just builds the bundle.)

## How it's built

- `DevScreen.swift` + `BlackoutPolicy.swift` — small AppKit menu-bar app (no Xcode project); `swiftc` compiles it.
- `dev-screen-ctl` — zsh control script (`connect`/`brightness`/`black`/`restore`/`disconnect`/`status`), bundled in Resources.
- `Info.plist` (`LSUIElement`), `build.sh`, `gen-icon.swift` (icon), `GUIDE.html`.
- Unsigned local build → runs Gatekeeper-clean when *you* build it (no Apple Developer account needed).
