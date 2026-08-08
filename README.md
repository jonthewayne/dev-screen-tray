# Dev Screen

A tiny macOS **menu-bar app** to remote into another Mac's screen (macOS Screen Sharing) in one click,
over **Tailscale** — from anywhere, not just the same Wi-Fi. Plus the physical-display controls
(black out / restore / lock) for driving a headless dev box unseen. Companion to
[ServeSim Tray](../serve-sim-tray).

## What you get

- Menu-bar icon (a display glyph) with a live **reachable / unreachable** status.
- **Connect (Screen Share)** blacks out the dev Mac and keeps its physical brightness at zero during the session.
- **Black Out Screen** / **Restore Brightness** / **Lock Dev Mac**.
- A separate **This Mac** section shows incoming Screen Sharing viewers and can sleep this display when
  the final viewer disconnects. It also re-sleeps an accidentally woken locked / screen-saver display
  after five seconds.
- **Start at Login**, in-app **Guide**.

During a screen-sharing session, **Restore Brightness** pauses blackout enforcement and **Black Out
Screen** resumes it. **Stop Screen Share** stops the monitor immediately, then blacks and sleeps the
dev Mac's display. No brightness polling runs while disconnected.

The local display safeguards do not run a permanent `caffeinate`. The app checks at its normal
eight-second status interval while idle, temporarily checks every two seconds while this Mac has a
possible incoming Screen Sharing viewer, and stops the faster check after a confirmed disconnect.
Two consecutive checks confirm both the session and its end, which filters brief port probes and
transient connections. The default-on **Sleep Display 5 Seconds After Lock / Screen Saver** control
uses one-shot macOS wake, lock, and screen-saver events instead of polling: a locked or screen-saver
display that wakes goes dark again after five seconds unless it is unlocked or an incoming viewer is
present. It requests display sleep through a five-second-bounded `pmset displaysleepnow` command, so a
stuck power-management request cannot block later manual or automatic actions. Both local controls
sleep only the display—the Mac and its agents keep running.
Either setting can be disabled under **Settings ▸ This Mac**.

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

- `DevScreen.swift` + the policy files — small AppKit menu-bar app (no Xcode project); `swiftc` compiles it.
- `dev-screen-ctl` — zsh control script for the remote dev Mac plus local viewer detection/display sleep, bundled in Resources.
- `Info.plist` (`LSUIElement`), `build.sh`, `gen-icon.swift` (icon), `GUIDE.html`.
- Unsigned local build → runs Gatekeeper-clean when *you* build it (no Apple Developer account needed).
