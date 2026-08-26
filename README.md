# PortMaster

A macOS notch app: a dynamic island under the MacBook notch that shows every
listening TCP port on your machine and lets you kill the process behind it —
one central place to manage what's up and running.

## How it works

- Collapsed, it hides behind the physical notch (a 2pt lip peeks out).
- **Hover the notch** → the island expands with the live port list.
- **Click ✕** on a row → sends SIGTERM to the owning process.
- **⌥-click ✕** → SIGKILL immediately. If SIGTERM doesn't stick within 3s,
  a red ⚡ button appears on the row to force kill.
- **Pin** (📌 in the header) keeps the island open; Esc or clicking anywhere
  outside collapses it.
- Right-click the island for Refresh / Quit.
- On displays without a notch it renders as a small pill at the top center
  showing the port count.

Ports are discovered with `lsof -iTCP -sTCP:LISTEN` (refreshed every 2s while
open, 15s in the background). Processes owned by other users (e.g. root
daemons) show a ⚠️ if a kill is denied — run the app with more privileges if
you need those.

## Build & run

```sh
./build.sh          # builds dist/PortMaster.app
open dist/PortMaster.app
```

For development:

```sh
swift run           # runs directly, no bundle needed
```

The app has no Dock icon or menu bar item (LSUIElement) — it lives entirely
in the notch. Quit via the power button in the island header or the
right-click menu.

## Install

Grab the latest `PortMaster-<version>.dmg` from the
[releases page](https://github.com/robimez/portmaster/releases) and drag
PortMaster into Applications (a zip is also available), or install via
`curl` (which skips the Gatekeeper quarantine entirely — see below):

```sh
curl -L https://github.com/robimez/portmaster/releases/latest/download/PortMaster.zip -o /tmp/pm.zip \
  && ditto -x -k /tmp/pm.zip /Applications
```

## Sharing (no notarization)

`./build.sh` produces `dist/PortMaster-<version>.zip` with a universal
(Apple Silicon + Intel) ad-hoc-signed binary. No Apple Developer account or
notarization involved — the trade-off is Gatekeeper friction for whoever
downloads it.

**What recipients must do (once):** downloads get quarantined, so the first
launch is blocked with "Apple could not verify…". Either:

1. Open **System Settings → Privacy & Security**, scroll to the
   *"PortMaster" was blocked* notice, click **Open Anyway** — or
2. Clear quarantine in Terminal before launching:

   ```sh
   xattr -dr com.apple.quarantine /Applications/PortMaster.app
   ```

**Frictionless alternatives:**

- **Install script / curl** — `curl` doesn't set the quarantine flag, so the
  one-liner in [Install](#install) skips Gatekeeper entirely.

- **Share the repo** — locally built apps are never quarantined:
  `git clone … && ./build.sh && open dist/PortMaster.app`.

## Releasing (maintainers)

Releases are automated via GitHub Actions — push a version tag:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

The workflow builds the universal app (the tag sets the app version via the
`VERSION` env var), verifies the binary is universal, and publishes a GitHub
Release with the zip and DMG attached plus auto-generated notes listing the
merged PRs (categorized by PR label via `.github/release.yml`; `feat/*` and
`fix/*` branches are auto-labeled).

## Debug

- `PORTMASTER_START_EXPANDED=1 swift run` launches with the island pinned
  open (useful for screenshots/testing).
