# omabitwarden

Bitwarden vault panel as an Omarchy shell plugin (kind: bar-widget): a lock icon in the bar toggles the vault panel; the icon keeps the shell plugin loaded.

## Features

- Unlock with the master password through the official `bw` CLI (`bw unlock --passwordenv`, master password never on argv).
- Spawns a local `bw serve` on `127.0.0.1:8087` for fast reads; attaches to (and never kills) a pre-existing serve.
- Search vault items by name or username; copy `username`, `password`, or TOTP — TOTP codes are computed locally in pure JS (RFC 6238), no bw subprocess per copy.
- Password and passphrase generator, straight to the clipboard.
- Clipboard secrets go via `wl-copy --sensitive` with a guarded 45s auto-clear.
- Auto-locks after 15 minutes idle; the session key lives in memory only (never argv, URL, or disk).

## Install

Prerequisite: the official Bitwarden CLI (`bw`) on your `PATH` (`/usr/bin/bw`).

```
omarchy plugin add <git-url> --enable
omarchy plugin enable crooy.omabitwarden right
```

The plugin lands in `~/.config/omarchy/plugins/crooy.omabitwarden`. Instead of the `enable` command you can manually add `{"id": "crooy.omabitwarden"}` to `bar.layout.right` in `~/.config/omarchy/shell.json`.

Dev install: clone the repo and symlink it into `~/.config/omarchy/plugins/crooy.omabitwarden`.

## Usage

- Left click the bar icon: toggle the panel; right click: lock.
- If a keybind is configured (e.g. `SUPER+B` → `omarchy-shell omabitwarden toggle`), use it.

## IPC

Target `omabitwarden`:

| Method    | Effect                     |
|-----------|----------------------------|
| `toggle`  | Show/hide the vault panel  |
| `lock`    | Lock the vault             |
| `status`  | Prints `locked`/`unlocked` |

Example: `omarchy-shell omabitwarden toggle`
